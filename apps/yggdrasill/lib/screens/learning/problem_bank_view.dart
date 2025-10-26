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
  double _manualRotation = 0.0; // 수동 회전각
  
  final GlobalKey _pdfViewKey = GlobalKey();
  final GlobalKey _containerKey = GlobalKey();
  
  // 저장된 문제 목록
  List<Map<String, dynamic>> _savedProblems = [];
  
  // 모드: true=크롭 모드, false=리스트 모드
  bool _isCropMode = false;
  
  // 선택된 문제 ID 목록
  Set<String> _selectedProblemIds = {};
  
  // 필터
  String _filterLevel = '전체'; // 전체, 초, 중, 고
  String _filterGrade = '전체';
  String _filterSubject = '전체';
  String _filterSource = '전체'; // 전체, 시중교재, 교과서, 내교재
  String _searchQuery = '';
  
  // 문제 유형 선택 (크롭 시)
  String _problemType = '주관식'; // 주관식, 객관식, 모두
  bool _isEssay = false; // 서술형 여부
  Rect? _choiceRect; // 선지 영역 (모두 선택 시)
  
  // 입력 모드: PDF 또는 붙여넣기
  bool _isPasteMode = false;
  
  @override
  void initState() {
    super.initState();
    _loadSavedProblems();
  }
  
  void _log(String s) { setState(() { _logs.insert(0, s); }); }
  
  Widget _buildLevelButton(String level) {
    final isSelected = _filterLevel == level;
    return InkWell(
      onTap: () => setState(() {
        _filterLevel = level;
        _filterGrade = '전체'; // 과정 변경 시 학년 초기화
      }),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1976D2) : const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isSelected ? const Color(0xFF1976D2) : Colors.white24),
        ),
        child: Text(level, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 13)),
      ),
    );
  }
  
  Widget _buildGradeDropdown() {
    List<String> items = ['전체'];
    if (_filterLevel == '중') {
      items.addAll(['중1-1', '중1-2', '중2-1', '중2-2', '중3-1', '중3-2']);
    } else if (_filterLevel == '고') {
      items.addAll(['고1', '고2', '고3']);
    } else if (_filterLevel == '초') {
      items.addAll(['초1', '초2', '초3', '초4', '초5', '초6']);
    }
    if (!items.contains(_filterGrade)) {
      _filterGrade = '전체';
    }
    return _buildFilterDropdown('학년', _filterGrade, items, (v) => setState(() => _filterGrade = v));
  }
  
  Widget _buildFilterDropdown(String label, String value, List<String> items, void Function(String) onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white24),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          dropdownColor: const Color(0xFF1F1F1F),
          style: const TextStyle(color: Colors.white70, fontSize: 13),
          items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
          onChanged: (v) { if (v != null) onChanged(v); },
          isDense: true,
        ),
      ),
    );
  }
  
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
                if (!_isCropMode) ...[
                  const SizedBox(width: 24),
                  // 과정 버튼
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final level in ['전체', '초', '중', '고'])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _buildLevelButton(level),
                        ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  // 학년 드롭다운 (과정에 따라 변경)
                  _buildGradeDropdown(),
                  const SizedBox(width: 12),
                  // 과목 드롭다운
                  _buildFilterDropdown('과목', _filterSubject, ['전체', '공통수학1', '공통수학2', '대수', '미적분1', '확률과 통계', '미적분2', '기하'], (v) => setState(() => _filterSubject = v)),
                  const SizedBox(width: 16),
                  // 교재 라디오
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final src in ['시중교재', '교과서', '내교재'])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            onTap: () => setState(() => _filterSource = src),
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: _filterSource == src ? const Color(0xFF1976D2) : Colors.transparent,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: _filterSource == src ? const Color(0xFF1976D2) : Colors.white24),
                              ),
                              child: Text(src, style: TextStyle(color: _filterSource == src ? Colors.white : Colors.white60, fontSize: 12)),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  // 검색 입력
                  SizedBox(
                    width: 200,
                    child: TextField(
                      onChanged: (v) => setState(() => _searchQuery = v),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '검색',
                        hintStyle: const TextStyle(color: Colors.white38),
                        prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 18),
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colors.white24)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colors.white24)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF1976D2))),
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (_isCropMode) ...[
                  if (_currentDoc != null) ...[
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white70),
                      onPressed: _currentPage > 1 ? () => setState(() { 
                        _currentPage--;
                        _selectedRect = null;
                        _croppedPreview = null;
                        _manualRotation = 0;
                      }) : null,
                    ),
                    Text('$_currentPage / ${_currentDoc!.pages.length}', style: const TextStyle(color: Colors.white70)),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward, color: Colors.white70),
                      onPressed: _currentPage < _currentDoc!.pages.length ? () => setState(() { 
                        _currentPage++;
                        _selectedRect = null;
                        _croppedPreview = null;
                        _manualRotation = 0;
                      }) : null,
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
                    FilledButton.icon(
                      onPressed: () => _deleteSelected(),
                      icon: const Icon(Icons.delete, size: 18),
                      label: Text('삭제 (${_selectedProblemIds.length}개)'),
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
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
    
    return GridView.builder(
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        childAspectRatio: 1.75, // 높이 2배 (3.5 → 1.75)
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _savedProblems.length,
      itemBuilder: (context, i) {
        final p = _savedProblems[i];
        final id = p['id'] as String? ?? '';
        final imageUrl = p['image_url'] as String? ?? '';
        final number = p['problem_number'] as String? ?? '번호 미지정';
        final subject = p['subject'] as String? ?? '';
        final isSelected = _selectedProblemIds.contains(id);
        
        return InkWell(
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
            decoration: BoxDecoration(
              color: const Color(0xFF262626),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected ? const Color(0xFF1976D2) : Colors.white24, 
                width: isSelected ? 3 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 첫줄: 번호 + 제목/출처 + 유형칩 + 체크박스
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: Row(
                    children: [
                      Text(
                        '${i + 1}',
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '중등 수학 1-1 · 쎈',
                          style: const TextStyle(color: Colors.white60, fontSize: 18),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // 유형 칩
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1976D2).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF1976D2), width: 1),
                        ),
                        child: const Text('주관', style: TextStyle(color: Color(0xFF64B5F6), fontSize: 11, fontWeight: FontWeight.w600)),
                      ),
                      if (isSelected) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.check_circle, color: Color(0xFF1976D2), size: 22),
                      ],
                    ],
                  ),
                ),
                // 둘째줄: 문제 이미지 (흰 배경, 상단 정렬, 너비 가득)
                Expanded(
                  child: Container(
                    width: double.infinity,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: imageUrl.isNotEmpty
                          ? SingleChildScrollView(
                              child: Image.network(imageUrl, fit: BoxFit.fitWidth, width: double.infinity),
                            )
                          : Container(color: const Color(0xFFEEEEEE)),
                    ),
                  ),
                ),
                // 셋째줄: 태그/상세
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: Text(
                    '난이도: 중 · 유형: 함수',
                    style: const TextStyle(color: Colors.white54, fontSize: 16.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  Widget _buildCropMode() {
    return Row(
      children: [
        // PDF 뷰어 또는 붙여넣기 (Expanded로 최대 확장)
        Expanded(
          child: _currentDoc == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FilledButton.icon(
                            onPressed: () => setState(() => _isPasteMode = false),
                            icon: const Icon(Icons.picture_as_pdf, size: 18),
                            label: const Text('PDF 드롭'),
                            style: FilledButton.styleFrom(
                              backgroundColor: !_isPasteMode ? const Color(0xFF1976D2) : const Color(0xFF616161),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: () => setState(() => _isPasteMode = true),
                            icon: const Icon(Icons.content_paste, size: 18),
                            label: const Text('붙여넣기'),
                            style: FilledButton.styleFrom(
                              backgroundColor: _isPasteMode ? const Color(0xFF1976D2) : const Color(0xFF616161),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Container(
                        width: 520,
                        height: 280,
                        decoration: BoxDecoration(
                          color: _dragOver ? const Color(0xFF23262C) : const Color(0xFF222222),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _dragOver ? const Color(0xFF64B5F6) : Colors.white24, width: 2),
                        ),
                        child: _isPasteMode
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    Icon(Icons.content_paste, color: Colors.white70, size: 48),
                                    SizedBox(height: 12),
                                    Text('Ctrl+V로 스크린샷 붙여넣기', style: TextStyle(color: Colors.white70, fontSize: 16)),
                                    SizedBox(height: 6),
                                    Text('어도비 뷰어 등에서 스크린샷 후 바로 붙여넣기', style: TextStyle(color: Colors.white38, fontSize: 13)),
                                  ],
                                ),
                              )
                            : _DropPdfArea(
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
                    ],
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
                      ? Stack(
                          children: [
                            Image.memory(_croppedPreview!, fit: BoxFit.contain),
                            // 가로 보조선 (중앙)
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 110, // 220 / 2
                              child: Container(
                                height: 1,
                                color: const Color(0xFF64B5F6).withOpacity(0.8),
                              ),
                            ),
                          ],
                        )
                      : Center(
                          child: Text('크롭 영역\n(${(_selectedRect!.width * 100).toStringAsFixed(0)}% × ${(_selectedRect!.height * 100).toStringAsFixed(0)}%)', 
                            style: const TextStyle(color: Colors.white54), textAlign: TextAlign.center),
                        ),
                ),
                // 수동 회전 조정
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('수동 회전', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.rotate_left, size: 18),
                            onPressed: () {
                              setState(() => _manualRotation -= 0.1);
                              _applyManualRotation();
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            color: Colors.white70,
                          ),
                          Expanded(
                            child: Slider(
                              value: _manualRotation.clamp(-2.0, 2.0),
                              min: -2.0,
                              max: 2.0,
                              divisions: 80,
                              label: '${_manualRotation.toStringAsFixed(1)}°',
                              onChanged: (v) {
                                setState(() => _manualRotation = v);
                                _applyManualRotation();
                              },
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.rotate_right, size: 18),
                            onPressed: () {
                              setState(() => _manualRotation += 0.1);
                              _applyManualRotation();
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            color: Colors.white70,
                          ),
                        ],
                      ),
                    ],
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
                          _manualRotation = 0;
                        }),
                        child: const Text('취소', style: TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white24, height: 1),
              ],
              // 문제 유형 선택
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('문제 유형', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final type in ['주관식', '객관식', '모두'])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: InkWell(
                                onTap: () => setState(() => _problemType = type),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  decoration: BoxDecoration(
                                    color: _problemType == type ? const Color(0xFF1976D2) : const Color(0xFF2A2A2A),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: _problemType == type ? const Color(0xFF1976D2) : Colors.white24),
                                  ),
                                  child: Text(type, style: TextStyle(color: _problemType == type ? Colors.white : Colors.white60, fontSize: 11), textAlign: TextAlign.center),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    InkWell(
                      onTap: () => setState(() => _isEssay = !_isEssay),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: _isEssay ? const Color(0xFF2E7D32) : const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _isEssay ? const Color(0xFF2E7D32) : Colors.white24),
                        ),
                        child: Text('서술형', style: TextStyle(color: _isEssay ? Colors.white : Colors.white60, fontSize: 11), textAlign: TextAlign.center),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white24, height: 1),
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
                                  key: ValueKey('page_$_currentPage'),
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
      final ui.Image fullImg = await rb.toImage(pixelRatio: 8.0); // B4 인쇄 품질
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
      final autoLeveled = _autoLevelImage(cropped);
      
      // 수동 회전 적용
      _croppedImage = autoLeveled;
      _updatePreviewWithRotation();
      _log('미리보기 생성 완료: ${cropW}x${cropH}');
    } catch (e) {
      _log('미리보기 생성 실패: $e');
    }
  }
  
  void _applyManualRotation() {
    if (_croppedImage == null) return;
    _updatePreviewWithRotation();
  }
  
  void _updatePreviewWithRotation() {
    if (_croppedImage == null) return;
    final rotated = img.copyRotate(_croppedImage!, angle: _manualRotation);
    final png = img.encodePng(rotated);
    setState(() {
      _croppedPreview = Uint8List.fromList(png);
    });
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
      
      // 수동 회전 반영
      final finalImage = img.copyRotate(_croppedImage!, angle: _manualRotation);
      final pngBytes = img.encodePng(finalImage);
      
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
  
  // 수평 자동 조절: Otsu + 여러 텍스트 라인 샘플링 + 중앙값
  img.Image _autoLevelImage(img.Image src) {
    try {
      final gray = img.grayscale(src);
      final w = gray.width;
      final h = gray.height;
      
      // 1) Otsu 임계값 계산
      final histogram = List<int>.filled(256, 0);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          histogram[gray.getPixel(x, y).luminance.toInt()]++;
        }
      }
      final threshold = _otsuThreshold(histogram, w * h);
      _log('Otsu 임계: $threshold');
      
      // 2) 상단 40% 영역에서 텍스트 라인 여러 개 샘플링
      final scanH = (h * 0.4).round();
      final List<double> angles = [];
      
      for (int y = 0; y < scanH; y += math.max(1, (h * 0.025).round())) {
        int blackCnt = 0;
        for (int x = (w * 0.1).round(); x < (w * 0.9).round(); x++) {
          if (gray.getPixel(x, y).luminance.toInt() < threshold) blackCnt++;
        }
        
        // 텍스트가 충분히 있는 행만 샘플
        if (blackCnt < w * 0.08) continue;
        
        // 해당 행의 좌우 끝 텍스트 위치
        int? leftX, rightX;
        for (int x = (w * 0.05).round(); x < (w * 0.95).round(); x++) {
          if (gray.getPixel(x, y).luminance.toInt() < threshold) {
            if (leftX == null) leftX = x;
            rightX = x;
          }
        }
        
        if (leftX == null || rightX == null || (rightX - leftX) < w * 0.25) continue;
        
        // 정밀 y 탐색 (±5px)
        int leftY = y, rightY = y;
        for (int dy = -5; dy <= 5; dy++) {
          final yy = (y + dy).clamp(0, h - 1);
          if (gray.getPixel(leftX, yy).luminance.toInt() < threshold) leftY = yy;
          if (gray.getPixel(rightX, yy).luminance.toInt() < threshold) rightY = yy;
        }
        
        // 각도 계산
        final slope = (rightY - leftY).toDouble() / (rightX - leftX).toDouble();
        final angleDeg = math.atan(slope) * 180 / math.pi;
        if (angleDeg.abs() < 3.0) angles.add(angleDeg);
      }
      
      if (angles.isEmpty) {
        _log('라인 샘플 부족');
        return src;
      }
      
      // 중앙값 사용 (이상치 제거)
      angles.sort();
      final median = angles[angles.length ~/ 2];
      _log('각도 샘플: ${angles.length}개, 중앙값=${median.toStringAsFixed(3)}°');
      
      if (median.abs() < 0.05) {
        _log('수평 보정 불필요');
        return src;
      }
      
      _log('수평 보정: ${median.toStringAsFixed(2)}°');
      return img.copyRotate(src, angle: -median);
    } catch (e) {
      _log('수평 보정 실패: $e');
      return src;
    }
  }
  
  int _otsuThreshold(List<int> histogram, int total) {
    double sum = 0;
    for (int i = 0; i < 256; i++) sum += i * histogram[i];
    double sumB = 0;
    int wB = 0;
    double maxVar = 0;
    int threshold = 0;
    for (int t = 0; t < 256; t++) {
      wB += histogram[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * histogram[t];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final varBetween = wB * wF * (mB - mF) * (mB - mF);
      if (varBetween > maxVar) {
        maxVar = varBetween;
        threshold = t;
      }
    }
    return threshold;
  }
  
  Future<void> _deleteSelected() async {
    if (_selectedProblemIds.isEmpty) return;
    try {
      final supa = Supabase.instance.client;
      for (final id in _selectedProblemIds) {
        await supa.from('problem_bank').delete().eq('id', id);
        // Storage도 삭제
        final prob = _savedProblems.firstWhere((p) => p['id'] == id, orElse: () => {});
        final imageUrl = prob['image_url'] as String? ?? '';
        if (imageUrl.isNotEmpty) {
          try {
            final path = imageUrl.split('/problem-images/').last;
            await supa.storage.from('problem-images').remove([path]);
          } catch (_) {}
        }
      }
      _log('${_selectedProblemIds.length}개 문제 삭제 완료');
      setState(() => _selectedProblemIds.clear());
      await _loadSavedProblems();
    } catch (e) {
      _log('삭제 실패: $e');
    }
  }
  
  Future<void> _printSelected() async {
    if (_selectedProblemIds.isEmpty) return;
    try {
      _log('인쇄 준비: ${_selectedProblemIds.length}개 문제');
      
      // 선택된 문제 가져오기
      final selected = _savedProblems.where((p) => _selectedProblemIds.contains(p['id'])).toList();
      
      // PDF 생성 (2×2 레이아웃, 상단 40% 하단 50%, 한 페이지 4문제)
      final doc = sf.PdfDocument();
      const double margin = 20; // 좌측 여백 감소
      const double pageWidth = 595;
      const double pageHeight = 842;
      const double gap = 20;
      const double colWidth = (pageWidth - margin * 2 - gap) / 2;
      const double totalH = pageHeight - margin * 2;
      const double topRowH = totalH * 0.4; // 위 40%
      const double bottomRowH = totalH * 0.5; // 아래 50% (10% 더)
      
      int problemNumber = 1;
      sf.PdfPage? currentPage;
      
      for (int i = 0; i < selected.length; i++) {
        final prob = selected[i];
        final imageUrl = prob['image_url'] as String? ?? '';
        if (imageUrl.isEmpty) continue;
        
        _log('다운로드: ${imageUrl.split('/').last}');
        final resp = await http.get(Uri.parse(imageUrl));
        if (resp.statusCode != 200) continue;
        
        final imgData = resp.bodyBytes;
        final decoded = img.decodePng(imgData);
        if (decoded == null) continue;
        
        final imgAspect = decoded.width / decoded.height;
        final displayWidth = colWidth;
        final displayHeight = displayWidth / imgAspect;
        
        // 페이지 내 위치 (0~3)
        final posInPage = i % 4;
        
        if (currentPage == null || posInPage == 0) {
          currentPage = doc.pages.add();
          
          // 가운데 세로 구분선 (굵게)
          currentPage.graphics.drawLine(
            sf.PdfPen(sf.PdfColor(160, 160, 160), width: 1.5),
            Offset(pageWidth / 2, margin),
            Offset(pageWidth / 2, pageHeight - margin),
          );
        }
        
        // 셀 위치 계산
        final col = posInPage % 2;
        final row = posInPage ~/ 2;
        final x = margin + col * (colWidth + gap);
        final y = margin + (row == 0 ? 0 : topRowH);
        final cellH = (row == 0) ? topRowH : bottomRowH;
        
        // 번호 그리기 (크고 굵게, 여백 추가)
        currentPage.graphics.drawString(
          '$problemNumber.',
          sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 16, style: sf.PdfFontStyle.bold),
          bounds: Rect.fromLTWH(x + 5, y + 5, colWidth, 20),
        );
        
        // 이미지 그리기
        final imgY = y + 25; // 번호 여백 5 + 높이 20
        final maxImgH = cellH - 25;
        final fitH = math.min(displayHeight, maxImgH);
        currentPage.graphics.drawImage(
          sf.PdfBitmap(imgData),
          Rect.fromLTWH(x, imgY, displayWidth, fitH),
        );
        
        problemNumber++;
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
