import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'textbook_pdf_service.dart';

/// PDF 쪽 좌표 영역을 찍은 PNG. region1k 는 실제로 찍은 영역(여백 포함, 쪽 기준 0..1000).
class TextbookReviewRenderedRegion {
  const TextbookReviewRenderedRegion({
    required this.bytes,
    required this.widthPx,
    required this.heightPx,
    required this.region1k,
    required this.rawPage,
  });

  final Uint8List bytes;
  final int widthPx;
  final int heightPx;
  final List<int> region1k;
  final int rawPage;
}

/// 문항검수용 — 해설 PDF(또는 본문 PDF)에서 `textbook_problem_solution_refs` 좌표 영역만 잘라 PNG로 만든다.
///
/// Stage 3에서 저장한 좌표([ymin, xmin, ymax, xmax], 0..1000)는 쪽 전체 기준이므로 pdfrx 부분 렌더(x, y, width, height)로
/// 그 영역만 고해상도로 찍는다. 잘라낸 이미지는 ai_think(textbook_problem_review)에 base64로 보내 Vision이 원본 해설을 전사한다.
class TextbookReviewSolutionImageService {
  TextbookReviewSolutionImageService({
    TextbookPdfService? pdfService,
    http.Client? httpClient,
  })  : _pdf = pdfService ?? TextbookPdfService(),
        _http = httpClient ?? http.Client();

  final TextbookPdfService _pdf;
  final http.Client _http;

  // 앱 전체가 함께 쓴다. 소단원 작업이 여러 개 동시에 돌아도 같은 PDF 는 한 번만 받고 한 번만 연다
  // (따로 받으면 같은 임시 파일을 서로 덮어써서 끝나지 않는다).
  static final Map<String, Future<PdfDocument?>> _docLoads = {};
  static final Map<String, PdfDocument> _docs = {};
  static final Map<String, Set<void Function(int received, int? total)>> _progressListeners = {};
  static final Map<String, ({DateTime at, String error})> _failures = {};

  /// 받기에 실패한 PDF 는 이 시간 동안 다시 받지 않고 바로 실패로 돌려준다(문항마다 다시 받지 않게).
  static const Duration kFailureCooldown = Duration(minutes: 2);

  /// 이 시간 동안 한 바이트도 오지 않으면 다운로드를 끊는다.
  static const Duration kStallTimeout = Duration(seconds: 60);

  /// 잘라낸 영역의 가로 목표 해상도. 2단 조판 해설 한 칸이 1100px면 수식 첨자까지 읽힌다.
  static const int kTargetCropWidthPx = 1100;
  static const int kMaxFullLongEdgePx = 5200;

  /// 좌표 주변 여백(0..1000 단위). 번호 글자나 마지막 줄이 잘리지 않게 조금 넓힌다.
  static const int kRegionPad1k = 10;

  String _docKey(String bookId, String gradeLabel, String kind) => '$bookId|$gradeLabel|$kind';

  /// 'body' 본문 · 'ans' 정답 · 그 밖은 해설 PDF
  static String _pdfKind(String sourceKind) => switch (sourceKind) {
        'body' => 'body',
        'ans' => 'ans',
        _ => 'sol',
      };

  /// PDF 쪽 수. PDF 가 등록되지 않았거나 받지 못하면 0.
  Future<int> pageCount({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String sourceKind,
  }) async {
    final doc = await _ensureDoc(academyId: academyId, bookId: bookId, gradeLabel: gradeLabel, kind: _pdfKind(sourceKind));
    return doc?.pages.length ?? 0;
  }

  /// 'body' 본문 · 'ans' 정답 · 그 밖은 해설
  static String pdfKindLabel(String sourceKind) => switch (_pdfKind(sourceKind)) {
        'body' => '본문',
        'ans' => '정답',
        _ => '해설',
      };

  /// 마지막으로 받기에 실패한 이유. 실패한 적 없거나 대기 시간이 지났으면 null.
  static String? loadError(String bookId, String gradeLabel, String sourceKind) {
    final f = _failures[_docKeyOf(bookId, gradeLabel, _pdfKind(sourceKind))];
    if (f == null || DateTime.now().difference(f.at) > kFailureCooldown) return null;
    return f.error;
  }

  static String _docKeyOf(String bookId, String gradeLabel, String kind) => '$bookId|$gradeLabel|$kind';

  /// PDF 를 받아 연다. [onProgress] 는 받는 중일 때 (받은 바이트, 전체 바이트) 로 불린다.
  Future<PdfDocument?> ensureSourcePdf({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String sourceKind,
    void Function(int received, int? total)? onProgress,
  }) =>
      _ensureDoc(
        academyId: academyId,
        bookId: bookId,
        gradeLabel: gradeLabel,
        kind: _pdfKind(sourceKind),
        onProgress: onProgress,
      );

  Future<PdfDocument?> _ensureDoc({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String kind,
    void Function(int received, int? total)? onProgress,
  }) async {
    final key = _docKey(bookId, gradeLabel, kind);
    final loaded = _docs[key];
    if (loaded != null) return loaded;
    final failed = _failures[key];
    if (failed != null && DateTime.now().difference(failed.at) <= kFailureCooldown) return null;
    if (onProgress != null) (_progressListeners[key] ??= {}).add(onProgress);
    try {
      return await _docLoads.putIfAbsent(key, () => _loadDoc(key, academyId, bookId, gradeLabel, kind));
    } finally {
      if (onProgress != null) _progressListeners[key]?.remove(onProgress);
    }
  }

  Future<PdfDocument?> _loadDoc(String key, String academyId, String bookId, String gradeLabel, String kind) async {
    try {
      final target = await _pdf.requestDownloadUrl(
        academyId: academyId,
        fileId: bookId,
        gradeLabel: gradeLabel,
        kind: kind,
        requireMigratedStorage: true,
      );
      if (target.url.isEmpty) throw Exception('${pdfKindLabel(kind)} PDF 주소를 받지 못했습니다');
      final tempDir = await getTemporaryDirectory();
      final safeBook = bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final safeGrade = gradeLabel.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final hash = (target.contentHash ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      final hashTag = hash.isEmpty ? '' : '_${hash.substring(0, hash.length < 16 ? hash.length : 16)}';
      final file = File(p.join(tempDir.path, 'review_${safeBook}_${safeGrade}_$kind$hashTag.pdf'));
      // 본문 PDF는 수백 MB라 매번 받으면 분 단위로 걸린다. 같은 해시·크기 파일이 있으면 그대로 쓴다.
      final expectedSize = target.fileSizeBytes;
      final cached = await file.exists() &&
          await file.length() > 0 &&
          (expectedSize == null || expectedSize <= 0 || await file.length() == expectedSize) &&
          (hashTag.isNotEmpty || (expectedSize != null && expectedSize > 0));
      if (!cached) {
        final reused = expectedSize != null &&
            expectedSize > 0 &&
            await _reuseLocalCopy(
              target: file,
              expectedSize: expectedSize,
              candidates: [
                File(p.join(tempDir.path, 'review_${safeBook}_${safeGrade}_$kind.pdf')),
                if (kind == 'body') File(p.join(tempDir.path, 'auth_${safeBook}_${gradeLabel}_body.pdf')),
              ],
            );
        if (!reused) {
          Object? lastError;
          for (var attempt = 0; attempt < 2; attempt++) {
            try {
              await _download(key, target.url, file, expectedSize);
              lastError = null;
              break;
            } catch (e) {
              lastError = e;
            }
          }
          if (lastError != null) throw lastError;
        }
      }
      final PdfDocument doc;
      try {
        doc = await PdfDocument.openFile(file.path);
      } catch (e) {
        // 깨진 파일이 캐시로 남으면 다음에도 같은 파일을 열게 된다.
        if (await file.exists()) await file.delete();
        throw Exception('${pdfKindLabel(kind)} PDF 를 열지 못했습니다: $e');
      }
      _docs[key] = doc;
      _failures.remove(key);
      return doc;
    } catch (e) {
      _failures[key] = (at: DateTime.now(), error: '$e');
      return null;
    } finally {
      _docLoads.remove(key);
    }
  }

  /// 같은 크기의 PDF 가 이미 받아져 있으면(예전 캐시 이름·단원·크롭 창 사본) 복사해 쓴다.
  static Future<bool> _reuseLocalCopy({
    required File target,
    required int expectedSize,
    required List<File> candidates,
  }) async {
    for (final c in candidates) {
      try {
        if (!await c.exists() || await c.length() != expectedSize) continue;
        final part = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.part');
        await c.copy(part.path);
        if (await part.length() != expectedSize) {
          await part.delete();
          continue;
        }
        await _replaceWith(part, target);
        return true;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  /// 다운로드마다 임시 파일을 따로 쓰고, 크기를 확인한 뒤에만 제자리에 놓는다.
  Future<void> _download(String key, String url, File file, int? expectedSize) async {
    final part = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.part');
    try {
      final res = await _http.send(http.Request('GET', Uri.parse(url))).timeout(kStallTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('${_kindOfKey(key)} PDF 받기 실패(${res.statusCode})');
      }
      final total = (expectedSize != null && expectedSize > 0) ? expectedSize : res.contentLength;
      final sink = part.openWrite();
      var received = 0;
      var lastReported = 0;
      try {
        await for (final chunk in res.stream.timeout(
          kStallTimeout,
          onTimeout: (sink) => sink.addError(
            TimeoutException('${_kindOfKey(key)} PDF 가 ${kStallTimeout.inSeconds}초 동안 오지 않았습니다'),
          ),
        )) {
          sink.add(chunk);
          received += chunk.length;
          if (received - lastReported >= 4 * 1024 * 1024) {
            lastReported = received;
            for (final l in [...?_progressListeners[key]]) {
              l(received, total);
            }
          }
        }
      } finally {
        await sink.close();
      }
      if (total != null && total > 0 && received != total) {
        throw Exception('${_kindOfKey(key)} PDF 를 끝까지 받지 못했습니다($received/$total바이트)');
      }
      await _replaceWith(part, file);
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  static String _kindOfKey(String key) => pdfKindLabel(key.split('|').last);

  static Future<void> _replaceWith(File part, File file) async {
    if (await file.exists()) await file.delete();
    await part.rename(file.path);
  }

  /// 해설 좌표 영역 PNG. PDF를 못 받거나 쪽·좌표가 없으면 null.
  Future<Uint8List?> renderSolutionCrop({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String sourceKind,
    required int rawPage,
    required List<int> region1k,
  }) async {
    final r = await renderRegion(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      sourceKind: sourceKind,
      rawPage: rawPage,
      region1k: region1k,
    );
    return r?.bytes;
  }

  /// 해설(또는 본문) PDF 한 쪽 전체를 PNG 로 찍는다(해설 번호 좌표가 어긋났을 때 쪽 전체에서 다시 찾는 폴백용).
  Future<TextbookReviewRenderedRegion?> renderFullPage({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String sourceKind,
    required int rawPage,
    int targetWidthPx = 1400,
  }) =>
      renderRegion(
        academyId: academyId,
        bookId: bookId,
        gradeLabel: gradeLabel,
        sourceKind: sourceKind,
        rawPage: rawPage,
        region1k: const [0, 0, 1000, 1000],
        pad1k: 0,
        targetWidthPx: targetWidthPx,
      );

  /// 본문/해설 PDF 한 쪽의 좌표 영역([ymin, xmin, ymax, xmax] 0..1000)을 PNG 로 찍는다.
  /// 반환값에는 실제로 찍은 영역(여백 포함)과 픽셀 크기가 들어 있어, 그 이미지 안의 좌표를 쪽 좌표로 되돌릴 수 있다.
  Future<TextbookReviewRenderedRegion?> renderRegion({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String sourceKind,
    required int rawPage,
    required List<int> region1k,
    int pad1k = kRegionPad1k,
    int targetWidthPx = kTargetCropWidthPx,
  }) async {
    if (rawPage < 1 || region1k.length != 4) return null;
    final doc = await _ensureDoc(academyId: academyId, bookId: bookId, gradeLabel: gradeLabel, kind: _pdfKind(sourceKind));
    if (doc == null || rawPage > doc.pages.length) return null;
    final page = doc.pages[rawPage - 1];

    final ymin = (region1k[0] - pad1k).clamp(0, 1000);
    final xmin = (region1k[1] - pad1k).clamp(0, 1000);
    final ymax = (region1k[2] + pad1k).clamp(0, 1000);
    final xmax = (region1k[3] + pad1k).clamp(0, 1000);
    if (ymax <= ymin || xmax <= xmin) return null;

    final cropWFrac = (xmax - xmin) / 1000.0;
    final cropHFrac = (ymax - ymin) / 1000.0;
    // 잘라낸 폭이 목표 해상도가 되도록 쪽 전체 배율을 정한다(너무 작은 영역이면 전체 배율 상한으로 묶는다).
    var fullW = targetWidthPx / cropWFrac;
    var fullH = fullW * (page.height / page.width);
    final longEdge = fullW > fullH ? fullW : fullH;
    if (longEdge > kMaxFullLongEdgePx) {
      final s = kMaxFullLongEdgePx / longEdge;
      fullW *= s;
      fullH *= s;
    }
    final x = (fullW * xmin / 1000.0).floor();
    final y = (fullH * ymin / 1000.0).floor();
    final w = (fullW * cropWFrac).ceil().clamp(1, fullW.ceil());
    final h = (fullH * cropHFrac).ceil().clamp(1, fullH.ceil());

    final img = await page.render(
      x: x,
      y: y,
      width: w,
      height: h,
      fullWidth: fullW,
      fullHeight: fullH,
      backgroundColor: const ui.Color(0xFFFFFFFF),
    );
    if (img == null) return null;
    try {
      final image = await img.createImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) return null;
        return TextbookReviewRenderedRegion(
          bytes: bytes.buffer.asUint8List(),
          widthPx: image.width,
          heightPx: image.height,
          region1k: [ymin, xmin, ymax, xmax],
          rawPage: rawPage,
        );
      } finally {
        image.dispose();
      }
    } finally {
      img.dispose();
    }
  }

  /// 연 PDF 는 앱 전체가 함께 쓰므로 여기서 닫지 않는다.
  void dispose() {}
}
