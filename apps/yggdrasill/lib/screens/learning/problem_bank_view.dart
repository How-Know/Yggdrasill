import 'package:flutter/material.dart';
import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart' as desktop_drop;
import 'dart:math' as math;
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../services/tenant_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:open_filex/open_filex.dart';
import 'package:http/http.dart' as http;

class ProblemBankView extends StatefulWidget {
  const ProblemBankView({super.key});
  @override
  State<ProblemBankView> createState() => _ProblemBankViewState();
}

class _ProblemBankViewState extends State<ProblemBankView> {
  bool _dragOver = false;
  List<String> _logs = [];
  pdfrx.PdfDocument? _currentDoc;
  String? _currentPath;
  int _currentPage = 1;
  
  // 수동 크롭 선택 영역
  Rect? _selectedRect;
  Offset? _dragStart;
  Offset? _dragCurrent;
  Uint8List? _croppedPreview;
  img.Image? _croppedImage; // 실제 크롭된 이미지 (서버 저장용)
  
  final GlobalKey _pdfViewKey = GlobalKey();
  final GlobalKey _containerKey = GlobalKey();
  
  // 저장된 문제 목록
  List<Map<String, dynamic>> _savedProblems = [];
  
  // 모드: true=크롭 모드, false=리스트 모드
  bool _isCropMode = false;
  
  // 선택된 문제 ID 목록
  Set<String> _selectedProblemIds = {};
  
  @override
  void initState() {
    super.initState();
    _loadSavedProblems();
  }
  
  void _log(String s) { setState(() { _logs.insert(0, s); }); }
  
  Future<void> _loadSavedProblems() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId();
      if (academyId == null) return;
      final supa = Supabase.instance.client;
      final data = await supa
          .from('problem_bank')
          .select('id,problem_number,image_url,subject,difficulty,tags,created_at')
          .eq('academy_id', academyId)
          .order('created_at', ascending: false)
          .limit(50);
      setState(() {
        _savedProblems = (data as List).cast<Map<String, dynamic>>();
      });
      _log('저장된 문제: ${_savedProblems.length}개');
    } catch (e) {
      _log('문제 로드 실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1F1F1F),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Text(_isCropMode ? '문제은행 · 크롭 모드' : '문제은행', 
                  style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w700)),
                const Spacer(),
                if (_isCropMode) ...[
                  if (_currentDoc != null) ...[
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white70),
                      onPressed: _currentPage > 1 ? () => setState(() => _currentPage--) : null,
                    ),
                    Text('$_currentPage / ${_currentDoc!.pages.length}', style: const TextStyle(color: Colors.white70)),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward, color: Colors.white70),
                      onPressed: _currentPage < _currentDoc!.pages.length ? () => setState(() => _currentPage++) : null,
                    ),
                    const SizedBox(width: 16),
                  ],
                  FilledButton.icon(
                    onPressed: () => setState(() { 
                      _isCropMode = false;
                      _currentDoc = null;
                      _currentPath = null;
                      _selectedRect = null;
                      _croppedPreview = null;
                      _croppedImage = null;
                    }),
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('종료'),
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF616161)),
                  ),
                ] else ...[
                  if (_selectedProblemIds.isNotEmpty) ...[
                    FilledButton.icon(
                      onPressed: () => _printSelected(),
                      icon: const Icon(Icons.print, size: 18),
                      label: Text('인쇄 (${_selectedProblemIds.length}개)'),
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => setState(() => _selectedProblemIds.clear()),
                      child: const Text('선택 해제', style: TextStyle(color: Colors.white70)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton.icon(
                    onPressed: () => setState(() => _isCropMode = true),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('문제 추가'),
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                  ),
                ],
              ],
            ),
          ),
          const Divider(color: Colors.white24, height: 1),
          Expanded(
            child: _isCropMode ? _buildCropMode() : _buildProblemList(),
          ),
        ],
      ),
    );
  }
  
  Widget _buildProblemList() {
    if (_savedProblems.isEmpty) {
      return const Center(
        child: Text('저장된 문제가 없습니다.\n우측 상단 "문제 추가" 버튼으로 시작하세요.', 
          style: TextStyle(color: Colors.white54, fontSize: 16), textAlign: TextAlign.center),
      );
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: _savedProblems.length,
      itemBuilder: (context, i) {
        final p = _savedProblems[i];
        final id = p['id'] as String? ?? '';
        final imageUrl = p['image_url'] as String? ?? '';
        final number = p['problem_number'] as String? ?? '번호 미지정';
        final subject = p['subject'] as String? ?? '';
        final isSelected = _selectedProblemIds.contains(id);
        
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
            width: 900, // 고정 너비
            child: InkWell(
              onTap: () {
                setState(() {
                  if (isSelected) {
                    _selectedProblemIds.remove(id);
                  } else {
                    _selectedProblemIds.add(id);
                  }
                });
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                height: 120,
                decoration: BoxDecoration(
                  color: const Color(0xFF262626),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? const Color(0xFF1976D2) : Colors.white24, 
                    width: isSelected ? 3 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    // 좌측: 이미지 (가로로 길게, 흰 배경)
                    Expanded(
                      flex: 5,
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.horizontal(left: Radius.circular(10)),
                        ),
                        child: ClipRRect(
                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
                          child: imageUrl.isNotEmpty
                              ? Image.network(imageUrl, fit: BoxFit.contain, height: double.infinity)
                              : Container(color: const Color(0xFFEEEEEE)),
                        ),
                      ),
                    ),
                    ),
                  // 우측: 정보 (작은 영역)
                  Container(
                    width: 180,
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            if (isSelected)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(Icons.check_circle, color: Color(0xFF1976D2), size: 20),
                              ),
                            Expanded(
                              child: Text(number, 
                                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (subject.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(subject, 
                            style: const TextStyle(color: Colors.white60, fontSize: 13),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  
  Widget _buildCropMode() {
    return Row(
      children: [
        // PDF 뷰어 (Expanded로 최대 확장)
        Expanded(
          child: _currentDoc == null
              ? Center(
                  child: Container(
                    width: 520,
                    height: 280,
                    decoration: BoxDecoration(
                      color: _dragOver ? const Color(0xFF23262C) : const Color(0xFF222222),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _dragOver ? const Color(0xFF64B5F6) : Colors.white24, width: 2),
                    ),
                    child: _DropPdfArea(
                      onDrag: (v) => setState(() => _dragOver = v),
                      onFiles: (paths) async {
                        if (paths.isEmpty) return;
                        final path = paths.first;
                        _log('PDF 로드: $path');
                        try {
                          final doc = await pdfrx.PdfDocument.openFile(path);
                          setState(() {
                            _currentDoc = doc;
                            _currentPath = path;
                            _currentPage = 1;
                          });
                          _log('${doc.pages.length}페이지 로드 완료');
                        } catch (e) {
                          _log('로드 실패: $e');
                        }
                      },
                    ),
                  ),
                )
              : _buildPdfViewer(),
        ),
        Container(width: 1, color: Colors.white24),
        // 우측: 로그 + 크롭 미리보기
        SizedBox(
          width: 280,
          child: Column(
            children: [
              // 크롭 미리보기
              if (_selectedRect != null) ...[
                Container(
                  height: 220,
                  color: const Color(0xFF222222),
                  padding: const EdgeInsets.all(8),
                  child: _croppedPreview != null
                      ? Image.memory(_croppedPreview!, fit: BoxFit.contain)
                      : Center(
                          child: Text('크롭 영역\n(${(_selectedRect!.width * 100).toStringAsFixed(0)}% × ${(_selectedRect!.height * 100).toStringAsFixed(0)}%)', 
                            style: const TextStyle(color: Colors.white54), textAlign: TextAlign.center),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _croppedImage != null ? () => _saveProblemToServer() : null,
                          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                          child: const Text('저장'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () => setState(() { 
                          _selectedRect = null; 
                          _dragStart = null; 
                          _dragCurrent = null;
                          _croppedPreview = null;
                          _croppedImage = null;
                        }),
                        child: const Text('취소', style: TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white24, height: 1),
              ],
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _logs.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(_logs[i], style: const TextStyle(color: Colors.white54, fontSize: 13)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPdfViewer() {
    final page = _currentDoc!.pages[_currentPage - 1];
    final pageSize = page.size;
    final aspect = pageSize.width / pageSize.height;
    
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400, maxHeight: 1800),
          child: AspectRatio(
            aspectRatio: aspect,
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5.0,
              boundaryMargin: const EdgeInsets.all(200),
              child: LayoutBuilder(
                builder: (context, cons) {
                  return GestureDetector(
                    key: _containerKey,
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (d) {
                      _log('드래그 시작');
                      final RenderBox? box = _containerKey.currentContext?.findRenderObject() as RenderBox?;
                      if (box == null) {
                        _log('RenderBox null');
                        return;
                      }
                      final local = box.globalToLocal(d.globalPosition);
                      final size = box.size;
                      setState(() {
                        _dragStart = Offset(
                          (local.dx / size.width).clamp(0.0, 1.0),
                          (local.dy / size.height).clamp(0.0, 1.0),
                        );
                        _dragCurrent = _dragStart;
                        _selectedRect = null;
                        _croppedPreview = null;
                      });
                    },
                    onPanUpdate: (d) {
                      final RenderBox? box = _containerKey.currentContext?.findRenderObject() as RenderBox?;
                      if (box == null) return;
                      final local = box.globalToLocal(d.globalPosition);
                      final size = box.size;
                      setState(() {
                        _dragCurrent = Offset(
                          (local.dx / size.width).clamp(0.0, 1.0),
                          (local.dy / size.height).clamp(0.0, 1.0),
                        );
                      });
                    },
                    onPanEnd: (d) async {
                      _log('드래그 종료');
                      if (_dragStart != null && _dragCurrent != null) {
                        final left = math.min(_dragStart!.dx, _dragCurrent!.dx).clamp(0.0, 1.0);
                        final top = math.min(_dragStart!.dy, _dragCurrent!.dy).clamp(0.0, 1.0);
                        final right = math.max(_dragStart!.dx, _dragCurrent!.dx).clamp(0.0, 1.0);
                        final bottom = math.max(_dragStart!.dy, _dragCurrent!.dy).clamp(0.0, 1.0);
                        
                        if (right - left < 0.01 || bottom - top < 0.01) {
                          _log('영역이 너무 작아 무시됨');
                          setState(() { _dragStart = null; _dragCurrent = null; });
                          return;
                        }
                        
                        setState(() {
                          _selectedRect = Rect.fromLTRB(left, top, right, bottom);
                          _dragStart = null;
                          _dragCurrent = null;
                        });
                        _log('영역 선택: ${(left*100).toStringAsFixed(0)},${(top*100).toStringAsFixed(0)} → ${(right*100).toStringAsFixed(0)},${(bottom*100).toStringAsFixed(0)}');
                        
                        // 크롭 미리보기 생성
                        await _generateCropPreview();
                      }
                    },
                    child: SizedBox(
                      width: cons.maxWidth,
                      height: cons.maxHeight,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: RepaintBoundary(
                              key: _pdfViewKey,
                              child: Container(
                                decoration: BoxDecoration(border: Border.all(color: Colors.white24, width: 2)),
                                child: pdfrx.PdfPageView(
                                  document: _currentDoc!,
                                  pageNumber: _currentPage,
                                ),
                              ),
                            ),
                          ),
                          // 드래그 중인 사각형
                          if (_dragStart != null && _dragCurrent != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _SelectionPainter(
                                    start: _dragStart!,
                                    current: _dragCurrent!,
                                  ),
                                ),
                              ),
                            ),
                          // 확정된 선택 영역
                          if (_selectedRect != null)
                            Positioned(
                              left: _selectedRect!.left * cons.maxWidth,
                              top: _selectedRect!.top * cons.maxHeight,
                              width: _selectedRect!.width * cons.maxWidth,
                              height: _selectedRect!.height * cons.maxHeight,
                              child: IgnorePointer(
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: const Color(0xFF1976D2), width: 3),
                                    color: const Color(0xFF1976D2).withOpacity(0.15),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
  
  Future<void> _generateCropPreview() async {
    if (_selectedRect == null) return;
    try {
      final RenderRepaintBoundary? rb = _pdfViewKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (rb == null) {
        _log('미리보기 생성 실패: 렌더 객체 없음');
        return;
      }
      
      _log('고해상도 캡처 중...');
      final ui.Image fullImg = await rb.toImage(pixelRatio: 6.0); // 고해상도
      final ByteData? bd = await fullImg.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) return;
      
      final bytes = bd.buffer.asUint8List();
      final decoded = img.decodePng(bytes);
      if (decoded == null) {
        _log('PNG 디코딩 실패');
        return;
      }
      
      // 선택 영역만 크롭 (약간 여유 추가로 우측 잘림 방지)
      final marginRel = 0.005; // 0.5% 여유
      final left = (_selectedRect!.left - marginRel).clamp(0.0, 1.0);
      final top = (_selectedRect!.top - marginRel).clamp(0.0, 1.0);
      final right = (_selectedRect!.left + _selectedRect!.width + marginRel).clamp(0.0, 1.0);
      final bottom = (_selectedRect!.top + _selectedRect!.height + marginRel).clamp(0.0, 1.0);
      
      final cropX = (left * decoded.width).round();
      final cropY = (top * decoded.height).round();
      final cropW = ((right - left) * decoded.width).round();
      final cropH = ((bottom - top) * decoded.height).round();
      
      _log('크롭: ${cropX},${cropY} ${cropW}x${cropH}');
      final cropped = img.copyCrop(decoded, x: cropX, y: cropY, width: cropW, height: cropH);
      
      // 수평 자동 조절 (회전각 탐지 후 보정)
      final corrected = _autoLevelImage(cropped);
      
      final croppedPng = img.encodePng(corrected);
      setState(() {
        _croppedImage = corrected; // 서버 저장용
        _croppedPreview = Uint8List.fromList(croppedPng);
      });
      _log('미리보기 생성 완료: ${cropW}x${cropH}');
    } catch (e) {
      _log('미리보기 생성 실패: $e');
    }
  }
  
  Future<void> _saveProblemToServer() async {
    if (_croppedImage == null) return;
    try {
      _log('서버 저장 중...');
      final academyId = await TenantService.instance.getActiveAcademyId();
      if (academyId == null) {
        _log('저장 실패: academy_id 없음');
        return;
      }
      
      final supa = Supabase.instance.client;
      final id = const Uuid().v4();
      final fileName = '$id.png';
      final pngBytes = img.encodePng(_croppedImage!);
      
      // Storage 업로드
      await supa.storage
          .from('problem-images')
          .uploadBinary('$academyId/$fileName', Uint8List.fromList(pngBytes));
      
      final imageUrl = supa.storage.from('problem-images').getPublicUrl('$academyId/$fileName');
      
      // DB 저장
      await supa.from('problem_bank').insert({
        'id': id,
        'academy_id': academyId,
        'problem_number': '', // 추후 입력
        'image_url': imageUrl,
        'subject': '',
        'difficulty': 0,
        'tags': [],
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      
      _log('저장 완료: $fileName');
      setState(() {
        _selectedRect = null;
        _croppedPreview = null;
        _croppedImage = null;
      });
      
      // 목록 새로고침
      await _loadSavedProblems();
    } catch (e) {
      _log('저장 실패: $e');
    }
  }
  
  // 수평 자동 조절: 맨 윗줄(텍스트 상단 라인)을 평평하게 보정
  img.Image _autoLevelImage(img.Image src) {
    try {
      final gray = img.grayscale(src);
      final w = gray.width;
      final h = gray.height;
      
      // 평균 밝기로 임계값 계산
      int sum = 0;
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          sum += gray.getPixel(x, y).luminance.toInt();
        }
      }
      final threshold = ((sum / (w * h)) * 0.75).round();
      
      // 맨 윗줄 찾기: 상단 10%에서 텍스트가 처음 나타나는 행
      int topTextRow = -1;
      final scanH = (h * 0.1).round();
      for (int y = 0; y < scanH; y++) {
        int blackCnt = 0;
        for (int x = (w * 0.1).round(); x < (w * 0.9).round(); x++) {
          if (gray.getPixel(x, y).luminance.toInt() < threshold) blackCnt++;
        }
        if (blackCnt > w * 0.05) { // 5% 이상 검은 픽셀
          topTextRow = y;
          break;
        }
      }
      
      if (topTextRow < 0 || topTextRow >= h - 2) {
        _log('윗줄 못 찾음');
        return src;
      }
      
      // 해당 행의 좌우 검은 픽셀 위치 찾기
      int? leftX, rightX;
      for (int x = (w * 0.05).round(); x < (w * 0.95).round(); x++) {
        if (gray.getPixel(x, topTextRow).luminance.toInt() < threshold) {
          if (leftX == null) leftX = x;
          rightX = x;
        }
      }
      
      if (leftX == null || rightX == null || (rightX - leftX) < w * 0.2) {
        _log('좌우 끝점 부족');
        return src;
      }
      
      // 좌우 끝점 y 좌표 정밀 탐색 (±3px 범위)
      int leftY = topTextRow, rightY = topTextRow;
      for (int dy = -3; dy <= 3; dy++) {
        final y = (topTextRow + dy).clamp(0, h - 1);
        if (gray.getPixel(leftX, y).luminance.toInt() < threshold) leftY = y;
        if (gray.getPixel(rightX, y).luminance.toInt() < threshold) rightY = y;
      }
      
      // 기울기 계산: (rightY - leftY) / (rightX - leftX)
      final slope = (rightY - leftY).toDouble() / (rightX - leftX).toDouble();
      final angleRad = math.atan(slope);
      final angleDeg = angleRad * 180 / math.pi;
      
      if (angleDeg.abs() < 0.08) {
        _log('수평 보정 불필요: ${angleDeg.toStringAsFixed(2)}°');
        return src;
      }
      
      _log('수평 보정: ${angleDeg.toStringAsFixed(2)}° (윗줄 기준)');
      return img.copyRotate(src, angle: -angleDeg);
    } catch (e) {
      _log('수평 보정 실패: $e');
      return src;
    }
  }
  
  Future<void> _printSelected() async {
    if (_selectedProblemIds.isEmpty) return;
    try {
      _log('인쇄 준비: ${_selectedProblemIds.length}개 문제');
      
      // 선택된 문제 가져오기
      final selected = _savedProblems.where((p) => _selectedProblemIds.contains(p['id'])).toList();
      
      // PDF 생성 (2단 레이아웃)
      final doc = sf.PdfDocument();
      const double margin = 30;
      const double pageWidth = 595; // A4 width (points)
      const double pageHeight = 842; // A4 height (points)
      const double gap = 20; // 컬럼 간 간격
      const double colWidth = (pageWidth - margin * 2 - gap) / 2; // 2단
      
      sf.PdfPage? currentPage;
      int currentCol = 0; // 0: 왼쪽, 1: 오른쪽
      double leftY = margin;
      double rightY = margin;
      
      for (final prob in selected) {
        final imageUrl = prob['image_url'] as String? ?? '';
        if (imageUrl.isEmpty) continue;
        
        _log('다운로드: ${imageUrl.split('/').last}');
        final resp = await http.get(Uri.parse(imageUrl));
        if (resp.statusCode != 200) continue;
        
        final imgData = resp.bodyBytes;
        final decoded = img.decodePng(imgData);
        if (decoded == null) continue;
        
        // 이미지 크기 계산 (컬럼 너비에 맞춤)
        final imgAspect = decoded.width / decoded.height;
        final displayWidth = colWidth;
        final displayHeight = displayWidth / imgAspect;
        
        // 현재 컬럼 Y 위치
        final currentY = (currentCol == 0) ? leftY : rightY;
        
        // 페이지 넘김 필요 여부 (현재 컬럼 기준)
        if (currentPage == null || currentY + displayHeight > pageHeight - margin) {
          // 왼쪽 컬럼이 가득 찼으면 오른쪽으로, 오른쪽도 가득 찼으면 새 페이지
          if (currentPage != null && currentCol == 0 && rightY + displayHeight <= pageHeight - margin) {
            currentCol = 1; // 오른쪽 컬럼으로
          } else {
            currentPage = doc.pages.add();
            leftY = margin;
            rightY = margin;
            currentCol = 0;
          }
        }
        
        // 이미지 그리기
        final x = (currentCol == 0) ? margin : (margin + colWidth + gap);
        final y = (currentCol == 0) ? leftY : rightY;
        
        if (currentPage != null) {
          currentPage.graphics.drawImage(
            sf.PdfBitmap(imgData),
            Rect.fromLTWH(x, y, displayWidth, displayHeight),
          );
        }
        
        // Y 위치 갱신
        if (currentCol == 0) {
          leftY = y + displayHeight + 16;
        } else {
          rightY = y + displayHeight + 16;
        }
        
        // 다음 문제는 반대 컬럼으로 (왼쪽↔오른쪽 번갈아)
        currentCol = 1 - currentCol;
      }
      
      // PDF 저장 및 열기
      final bytes = await doc.save();
      doc.dispose();
      
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/problems_${DateTime.now().millisecondsSinceEpoch}.pdf');
      await file.writeAsBytes(bytes);
      
      _log('PDF 생성 완료: ${file.path}');
      await OpenFilex.open(file.path);
      
      setState(() => _selectedProblemIds.clear());
    } catch (e, st) {
      _log('인쇄 실패: $e');
      print('[PRINT][ERROR] $e\n$st');
    }
  }
}

class _SelectionPainter extends CustomPainter {
  final Offset start;
  final Offset current;
  _SelectionPainter({required this.start, required this.current});
  
  @override
  void paint(Canvas canvas, Size size) {
    final left = math.min(start.dx, current.dx) * size.width;
    final top = math.min(start.dy, current.dy) * size.height;
    final right = math.max(start.dx, current.dx) * size.width;
    final bottom = math.max(start.dy, current.dy) * size.height;
    
    final rect = Rect.fromLTRB(left, top, right, bottom);
    final paint = Paint()
      ..color = const Color(0xFF64B5F6).withOpacity(0.2)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, paint);
    
    final borderPaint = Paint()
      ..color = const Color(0xFF64B5F6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect, borderPaint);
  }
  
  @override
  bool shouldRepaint(_SelectionPainter old) => old.start != start || old.current != current;
}

class _DropPdfArea extends StatelessWidget {
  final void Function(bool) onDrag;
  final Future<void> Function(List<String> paths) onFiles;
  const _DropPdfArea({required this.onDrag, required this.onFiles});
  
  @override
  Widget build(BuildContext context) {
    return desktop_drop.DropTarget(
      onDragEntered: (_) => onDrag(true),
      onDragExited: (_) => onDrag(false),
      onDragDone: (detail) async {
        onDrag(false);
        final paths = detail.files
            .where((f) => f.mimeType == 'application/pdf' || f.name.toLowerCase().endsWith('.pdf'))
            .map((f) => f.path ?? '')
            .where((p) => p.isNotEmpty)
            .toList();
        if (paths.isEmpty) return;
        await onFiles(paths);
      },
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.picture_as_pdf, color: Colors.white70, size: 48),
            SizedBox(height: 12),
            Text('여기에 PDF 파일을 드롭하세요', style: TextStyle(color: Colors.white70, fontSize: 16)),
            SizedBox(height: 6),
            Text('드래그로 문제 영역 선택 → 저장', style: TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
