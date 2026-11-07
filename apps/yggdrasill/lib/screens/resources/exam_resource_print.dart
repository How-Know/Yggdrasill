import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../services/learning_problem_bank_service.dart';
import '../../services/mock_exam_resource_service.dart';
import '../../services/tenant_service.dart';
import 'exam_preset_support.dart';

/// 자료 메뉴에서 내신 프리셋·모의고사 원본을 인쇄 파일로 준비한다.
class ExamResourcePrint {
  ExamResourcePrint({
    LearningProblemBankService? problemBank,
    MockExamResourceService? mockExams,
  })  : _problemBank = problemBank ?? LearningProblemBankService(),
        _mockExams = mockExams ?? MockExamResourceService();

  final LearningProblemBankService _problemBank;
  final MockExamResourceService _mockExams;

  Future<({String path, String paperSize})> preparePresetPdf({
    required LearningProblemDocumentExportPreset preset,
    required void Function(String message) onProgress,
  }) async {
    final academyId = await _academyId();
    final job = await _ensurePresetExport(
      academyId: academyId,
      preset: preset,
      onProgress: onProgress,
    );
    onProgress('프리셋 PDF를 받는 중입니다...');
    final url = await _problemBank.resolveExportPdfUrl(job);
    if (url.trim().isEmpty) {
      throw StateError('프리셋 PDF 주소를 받지 못했습니다.');
    }
    final bytes = await _problemBank.downloadPdfBytesFromUrl(url);
    final path = await _writeTempPdf(bytes, 'res_exam_preset_');
    final paperSize = preset.paperSize.trim().isNotEmpty
        ? preset.paperSize.trim()
        : job.paperSize.trim();
    return (path: path, paperSize: paperSize);
  }

  Future<String> prepareMockExamOriginalPdf({
    required MockExamResourceCard card,
    required void Function(String message) onProgress,
  }) async {
    if (card.storagePath.trim().isEmpty) {
      throw StateError('모의고사 원본 PDF가 없습니다.');
    }
    onProgress('모의고사 원본을 받는 중입니다...');
    final url = await _mockExams.signedPaperUrl(card);
    final bytes = await _problemBank.downloadPdfBytesFromUrl(url);
    return _writeTempPdf(bytes, 'res_exam_mock_');
  }

  /// 모의고사 정답·해설 원본. 파일이 없으면 null.
  Future<String?> prepareMockExamSolutionPdf({
    required MockExamResourceCard card,
    required void Function(String message) onProgress,
  }) async {
    onProgress('정답·해설 원본을 찾는 중입니다...');
    final url = await _mockExams.signedSolutionUrl(card);
    if (url == null || url.trim().isEmpty) return null;
    onProgress('정답·해설 원본을 받는 중입니다...');
    final bytes = await _problemBank.downloadPdfBytesFromUrl(url);
    return _writeTempPdf(bytes, 'res_exam_mock_sol_');
  }

  /// 페이지 상자를 고른 용지에 맞춘다. 이미 그 크기면 원본 경로를 그대로 돌려준다.
  /// 프린터는 PDF 페이지 상자로 용지를 고르므로, 용지 이름만 보내면 트레이를 못 찾는다.
  Future<String> fitPdfToPaper({
    required String inputPath,
    required String paperSize,
  }) async {
    final portrait = _paperPortraitPoints(paperSize);
    if (portrait == null) {
      throw StateError('지원하지 않는 용지입니다.');
    }
    final srcBytes = await File(inputPath).readAsBytes();
    final src = sf.PdfDocument(inputBytes: srcBytes);
    final dst = sf.PdfDocument();
    try {
      final pageCount = src.pages.count;
      if (pageCount <= 0) {
        throw StateError('인쇄할 페이지가 없습니다.');
      }
      var needsFit = false;
      for (var i = 0; i < pageCount; i++) {
        final srcSize = src.pages[i].size;
        final target = _orientPaper(portrait, srcSize);
        if (!_nearSize(srcSize, target)) {
          needsFit = true;
          break;
        }
      }
      if (!needsFit) return inputPath;
      try {
        dst.pageSettings.margins.all = 0;
      } catch (_) {}
      for (var i = 0; i < pageCount; i++) {
        final srcPage = src.pages[i];
        final srcSize = srcPage.size;
        final target = _orientPaper(portrait, srcSize);
        try {
          dst.pageSettings.size = target;
          dst.pageSettings.margins.all = 0;
        } catch (_) {}
        final template = srcPage.createTemplate();
        final page = dst.pages.add();
        page.graphics.drawPdfTemplate(
          template,
          Offset.zero,
          Size(target.width, target.height),
        );
      }
      final outBytes = await dst.save();
      return _writeTempPdf(outBytes, 'res_exam_fit_');
    } finally {
      src.dispose();
      dst.dispose();
    }
  }

  Future<String> _academyId() async {
    final academyId =
        (await TenantService.instance.getActiveAcademyId() ?? '').trim();
    if (academyId.isEmpty) {
      throw StateError('학원 정보를 찾지 못했습니다.');
    }
    return academyId;
  }

  Size? _paperPortraitPoints(String raw) {
    final normalized =
        raw.trim().toUpperCase().replaceAll(RegExp(r'[\s\-_]+'), '');
    switch (normalized) {
      case 'A4':
        return const Size(595, 842);
      case 'B4':
      case 'B4JIS':
      case 'JISB4':
        // JIS B4 257×364mm. 숙제 인쇄와 같은 포인트 크기.
        return const Size(729, 1032);
      case '8K':
      case 'K8':
      case 'PRC8K':
      case 'ROC8K':
        // Konica 8K 270×390mm.
        return const Size(765.35, 1105.51);
      default:
        return null;
    }
  }

  Size _orientPaper(Size portrait, Size source) {
    final landscape = source.width > source.height;
    if (!landscape) return portrait;
    return Size(portrait.height, portrait.width);
  }

  bool _nearSize(Size a, Size b) {
    bool near(double x, double y) => (x - y).abs() <= 8;
    return near(a.width, b.width) && near(a.height, b.height);
  }

  Future<String> _writeTempPdf(List<int> bytes, String prefix) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(
      dir.path,
      '$prefix${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<LearningProblemExportJob> _ensurePresetExport({
    required String academyId,
    required LearningProblemDocumentExportPreset preset,
    required void Function(String message) onProgress,
  }) async {
    final documentId = preset.sourceDocumentId.trim().isNotEmpty
        ? preset.sourceDocumentId.trim()
        : preset.documentId.trim();
    if (documentId.isEmpty) {
      throw StateError('프리셋에 연결된 문제 문서가 없습니다.');
    }
    final selectedQuestionUids = _selectedQuestionUids(preset);
    if (selectedQuestionUids.isEmpty) {
      throw StateError('프리셋에 인쇄할 문항이 없습니다.');
    }

    final renderConfig = preset.renderConfig;
    final templateProfile =
        preset.templateProfile.isNotEmpty ? preset.templateProfile : 'csat';
    final paperSize = preset.paperSize.isNotEmpty ? preset.paperSize : 'A4';
    final includeAnswerSheet = _parseBool(
      renderConfig['includeAnswerSheet'],
      fallback: false,
    );
    final includeExplanation = _parseBool(
      renderConfig['includeExplanation'],
      fallback: false,
    );
    final followsOriginal = naesinLinkKeyOfPreset(preset).isNotEmpty;
    final hasOriginalPolicy =
        renderConfig['naesinOriginalModePolicyVersion'] == 1;
    final renderHash = followsOriginal && !hasOriginalPolicy
        ? ''
        : '${renderConfig['renderHash'] ?? ''}'.trim();
    final options = <String, dynamic>{
      ...renderConfig,
      'includeAnswerSheet': includeAnswerSheet,
      'includeExplanation': includeExplanation,
      if (followsOriginal) 'naesinOriginalModePolicyVersion': 1,
      if (renderHash.isNotEmpty) 'renderHash': renderHash,
      'previewOnly': false,
    };

    bool compatible(LearningProblemExportJob job) {
      final trimmedTemplate = templateProfile.trim();
      final expectedTemplate =
          (trimmedTemplate == 'assignment' ||
                  trimmedTemplate == 'gyeongsin' ||
                  trimmedTemplate == 'neungin' ||
                  trimmedTemplate == 'daeryun' ||
                  trimmedTemplate == 'dongdo' ||
                  trimmedTemplate == 'soseon' ||
                  trimmedTemplate == 'oseong' ||
                  trimmedTemplate == 'jeonghwa' ||
                  trimmedTemplate == 'hwanggeum')
              ? 'naesin'
              : templateProfile;
      final jobOptionTemplate =
          '${job.options['templateProfile'] ?? ''}'.trim();
      if (jobOptionTemplate.isNotEmpty &&
          jobOptionTemplate != trimmedTemplate) {
        return false;
      }
      final wantCover = _parseBool(
        renderConfig['includeCoverPage'],
        fallback: false,
      );
      final jobCover = _parseBool(
        job.options['includeCoverPage'],
        fallback: false,
      );
      if (wantCover != jobCover) return false;
      if (wantCover) {
        final defaultBlank = trimmedTemplate == 'mock' ||
            trimmedTemplate == 'csat' ||
            trimmedTemplate == 'gyeongsin' ||
            trimmedTemplate == 'naesin';
        final wantBlank = _parseBool(
          renderConfig['includeCoverBlankPage'] ??
              (renderConfig['coverPageTexts'] is Map
                  ? (renderConfig['coverPageTexts']
                      as Map)['includeCoverBlankPage']
                  : null),
          fallback: defaultBlank,
        );
        final jobBlank = _parseBool(
          job.options['includeCoverBlankPage'] ??
              (job.options['coverPageTexts'] is Map
                  ? (job.options['coverPageTexts']
                      as Map)['includeCoverBlankPage']
                  : null),
          fallback: defaultBlank,
        );
        if (wantBlank != jobBlank) return false;
      }
      if (renderConfig['pageColumnQuestionCounts'] is List &&
          (renderConfig['pageColumnQuestionCounts'] as List).isNotEmpty) {
        final wantCounts =
            '${renderConfig['pageColumnQuestionCounts']}'.trim();
        final jobCounts =
            '${job.options['pageColumnQuestionCounts'] ?? const <dynamic>[]}'
                .trim();
        if (wantCounts != jobCounts) return false;
      }
      final jobFollowsOriginal =
          job.options['naesinOriginalModePolicyVersion'] == 1;
      return !job.previewOnly &&
          (!followsOriginal || jobFollowsOriginal) &&
          job.documentId.trim() == documentId &&
          job.templateProfile.trim() == expectedTemplate.trim() &&
          job.paperSize.trim().toUpperCase() ==
              paperSize.trim().toUpperCase() &&
          job.includeAnswerSheet == includeAnswerSheet &&
          job.includeExplanation == includeExplanation &&
          _sameUids(job.selectedQuestionUids, selectedQuestionUids);
    }

    Future<bool> reusable(LearningProblemExportJob job) async {
      if (job.status.trim() != 'completed') return false;
      if (job.outputUrl.trim().isEmpty &&
          job.outputStoragePath.trim().isEmpty) {
        return false;
      }
      return !await _problemBank.hasQuestionRevisionsAfterExport(
        academyId: academyId,
        job: job,
      );
    }

    if (renderHash.isNotEmpty) {
      onProgress('기존 프리셋 PDF를 확인하는 중입니다...');
      final hashed = await _problemBank.findReusableCompletedExport(
        academyId: academyId,
        renderHash: renderHash,
        previewOnly: false,
      );
      if (hashed != null && await reusable(hashed)) return hashed;
    }

    onProgress('프리셋 PDF를 확인하는 중입니다...');
    final recent = await _problemBank.listExportJobs(
      academyId: academyId,
      documentId: documentId,
      previewOnly: false,
      limit: 20,
    );
    final compatibleJobs = recent.where(compatible).toList(growable: false);
    for (final job in compatibleJobs) {
      if (await reusable(job)) {
        onProgress('기존 프리셋 PDF를 재사용합니다...');
        return job;
      }
    }
    for (final job in compatibleJobs) {
      if (!job.isTerminal) {
        onProgress('진행 중인 프리셋 PDF 생성을 기다립니다...');
        return _wait(academyId: academyId, job: job, onProgress: onProgress);
      }
    }

    onProgress('프리셋 PDF 생성을 요청하는 중입니다...');
    final queued = await _problemBank.createExportJob(
      academyId: academyId,
      documentId: documentId,
      templateProfile: templateProfile,
      paperSize: paperSize,
      includeAnswerSheet: includeAnswerSheet,
      includeExplanation: includeExplanation,
      selectedQuestionUids: selectedQuestionUids,
      renderHash: renderHash,
      previewOnly: false,
      options: options,
    );
    return _wait(academyId: academyId, job: queued, onProgress: onProgress);
  }

  Future<LearningProblemExportJob> _wait({
    required String academyId,
    required LearningProblemExportJob job,
    required void Function(String message) onProgress,
  }) async {
    var current = job;
    for (var attempt = 0; attempt < 60; attempt += 1) {
      if (current.isTerminal) break;
      onProgress('프리셋 PDF 생성 중입니다...');
      await Future<void>.delayed(const Duration(seconds: 2));
      final latest = await _problemBank.getExportJob(
        academyId: academyId,
        jobId: current.id,
      );
      if (latest != null) current = latest;
      if (current.isTerminal) break;
    }
    final status = current.status.trim();
    if (status == 'completed' &&
        (current.outputUrl.trim().isNotEmpty ||
            current.outputStoragePath.trim().isNotEmpty)) {
      return current;
    }
    if (status == 'failed' || status == 'cancelled') {
      final detail = current.errorMessage.trim().isNotEmpty
          ? current.errorMessage.trim()
          : current.errorCode.trim();
      throw StateError(
        detail.isEmpty
            ? '프리셋 PDF 생성에 실패했습니다. (상태: $status)'
            : '프리셋 PDF 생성에 실패했습니다. $detail',
      );
    }
    throw StateError(
      '프리셋 PDF 생성 대기 시간이 120초를 초과했습니다. (현재 상태: $status)',
    );
  }

  List<String> _selectedQuestionUids(
    LearningProblemDocumentExportPreset preset,
  ) {
    if (preset.selectedQuestionUids.isNotEmpty) {
      return preset.selectedQuestionUids
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    List<String> parse(dynamic raw) {
      if (raw is! List) return const <String>[];
      return raw
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }

    final renderConfig = preset.renderConfig;
    final fromOrdered = parse(renderConfig['selectedQuestionUidsOrdered']);
    if (fromOrdered.isNotEmpty) return fromOrdered;
    final fromLegacy = parse(renderConfig['selectedQuestionIdsOrdered']);
    if (fromLegacy.isNotEmpty) return fromLegacy;
    final fromRaw = parse(renderConfig['selectedQuestionUids']);
    if (fromRaw.isNotEmpty) return fromRaw;
    return parse(renderConfig['selectedQuestionIds']);
  }

  bool _parseBool(dynamic raw, {required bool fallback}) {
    if (raw is bool) return raw;
    final text = '$raw'.trim().toLowerCase();
    if (text.isEmpty) return fallback;
    if (text == 'true' || text == '1' || text == 'yes' || text == 'y') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no' || text == 'n') {
      return false;
    }
    return fallback;
  }

  bool _sameUids(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i += 1) {
      if (left[i].trim() != right[i].trim()) return false;
    }
    return true;
  }
}
