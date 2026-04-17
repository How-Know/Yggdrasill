import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/problem_bank_service.dart';
import '../problem_bank_models.dart';

/// 학습앱의 `범위 선택` + `추출 문서 트리`와 동일한 UX를 제공하는 매니저 전용 다이얼로그.
///
/// - 상단: 교육과정 / 초중고 / 세부 과정 / 출처 필터(학습앱 필터바와 동일 항목/레이블).
/// - 중단: 문서명(파일명) 검색창.
/// - 하단: `school_past`일 때는 학교 → 연도 → 문서 트리, 그 외에는 평면 목록.
/// - 항목 우측: hover 시 등장하는 X 버튼으로 하드삭제(호출부에서 확인 모달 처리).
class ProblemBankSyncedListDialog extends StatefulWidget {
  const ProblemBankSyncedListDialog({
    super.key,
    required this.academyId,
    required this.service,
    required this.curriculumLabels,
    required this.sourceTypeLabels,
    required this.initialCurriculumCode,
    required this.initialSchoolLevel,
    required this.initialDetailedCourse,
    required this.initialSourceTypeCode,
    required this.initialSearchText,
    required this.initialSelectedDocumentId,
    required this.onDeleteDocument,
  });

  final String academyId;
  final ProblemBankService service;
  final Map<String, String> curriculumLabels;
  final Map<String, String> sourceTypeLabels;
  final String initialCurriculumCode;
  final String initialSchoolLevel;
  final String initialDetailedCourse;
  final String initialSourceTypeCode;
  final String initialSearchText;
  final String? initialSelectedDocumentId;

  /// 삭제 동작을 호출부로 위임(서비스 호출 + 상태 동기화를 호출부가 담당).
  ///
  /// `true`를 반환하면 다이얼로그 내부 리스트에서도 해당 문서를 즉시 제거한다.
  final Future<bool> Function(ProblemBankDocument doc) onDeleteDocument;

  @override
  State<ProblemBankSyncedListDialog> createState() =>
      _ProblemBankSyncedListDialogState();
}

class _ProblemBankSyncedListDialogState
    extends State<ProblemBankSyncedListDialog> {
  static const Color _bg = Color(0xFF0B1112);
  static const Color _panel = Color(0xFF15181C);
  static const Color _field = Color(0xFF101418);
  static const Color _border = Color(0xFF223131);
  static const Color _text = Color(0xFFEAF2F2);
  static const Color _textSub = Color(0xFF9FB3B3);
  static const Color _accent = Color(0xFF33A373);

  static const List<String> _levelOptions = <String>['전체', '초', '중', '고'];
  static const List<String> _detailedCourseOptions = <String>[
    '전체',
    '초1', '초2', '초3', '초4', '초5', '초6',
    '중1', '중2', '중3',
    '고1', '고2', '고3',
    '공통수학1', '공통수학2',
    '대수', '미적분1', '미적분2', '확률과 통계', '기하', '수학Ⅰ', '수학Ⅱ',
  ];
  static const String _unspecifiedSchool = '학교 미지정';

  late String _selectedCurriculumCode;
  late String _selectedSchoolLevel;
  late String _selectedDetailedCourse;
  late String _selectedSourceTypeCode;
  late TextEditingController _searchCtrl;

  bool _isLoading = false;
  String? _errorMessage;
  List<ProblemBankDocument> _documents = const <ProblemBankDocument>[];
  final Set<String> _deleting = <String>{};
  final Set<String> _expandedSchools = <String>{};
  final Set<String> _expandedYearBuckets = <String>{};

  @override
  void initState() {
    super.initState();
    _selectedCurriculumCode = widget.initialCurriculumCode.trim().isEmpty
        ? (widget.curriculumLabels.keys.isNotEmpty
            ? widget.curriculumLabels.keys.first
            : 'rev_2022')
        : widget.initialCurriculumCode.trim();
    _selectedSchoolLevel = widget.initialSchoolLevel.trim().isEmpty
        ? '전체'
        : widget.initialSchoolLevel.trim();
    _selectedDetailedCourse = widget.initialDetailedCourse.trim().isEmpty
        ? '전체'
        : widget.initialDetailedCourse.trim();
    _selectedSourceTypeCode = widget.initialSourceTypeCode.trim().isEmpty
        ? (widget.sourceTypeLabels.keys.isNotEmpty
            ? widget.sourceTypeLabels.keys.first
            : 'school_past')
        : widget.initialSourceTypeCode.trim();
    _searchCtrl = TextEditingController(text: widget.initialSearchText);
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final docs = await widget.service.listSyncedReadyDocuments(
        academyId: widget.academyId,
        curriculumCode:
            normalizePbCurriculumCodeForSync(_selectedCurriculumCode),
        schoolLevel: _selectedSchoolLevel,
        detailedCourse: _selectedDetailedCourse,
        sourceTypeCode: _selectedSourceTypeCode,
      );
      if (!mounted) return;
      setState(() {
        _documents = docs;
        _isLoading = false;
        _expandedSchools.clear();
        _expandedYearBuckets.clear();
        final sel = widget.initialSelectedDocumentId?.trim();
        if (sel != null && sel.isNotEmpty) {
          for (final doc in docs) {
            if (doc.id != sel) continue;
            final school = _schoolLabel(doc);
            _expandedSchools.add(school);
            _expandedYearBuckets.add('$school|${_yearLabel(doc)}');
            break;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _documents = const <ProblemBankDocument>[];
        _isLoading = false;
        _errorMessage = '목록을 불러오지 못했습니다: $e';
      });
    }
  }

  List<ProblemBankDocument> get _filteredDocuments {
    final needle = _searchCtrl.text.trim().toLowerCase();
    if (needle.isEmpty) return _documents;
    return _documents.where((doc) {
      final name = doc.sourceFilename.toLowerCase();
      final school = doc.schoolName.toLowerCase();
      final grade = doc.gradeLabel.toLowerCase();
      final course = doc.courseLabel.toLowerCase();
      return name.contains(needle) ||
          school.contains(needle) ||
          grade.contains(needle) ||
          course.contains(needle);
    }).toList(growable: false);
  }

  Future<void> _handleDelete(ProblemBankDocument doc) async {
    if (_deleting.contains(doc.id)) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: const Text(
          '문서 하드삭제',
          style: TextStyle(color: _text, fontWeight: FontWeight.w800),
        ),
        content: Text(
          '"${doc.sourceFilename}" 문서를 완전히 삭제할까요?\n연결된 문항/미리보기도 함께 제거됩니다.',
          style: const TextStyle(color: _textSub, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDE6A73),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _deleting.add(doc.id));
    try {
      final ok = await widget.onDeleteDocument(doc);
      if (!mounted) return;
      if (ok) {
        setState(() {
          _documents = _documents
              .where((d) => d.id != doc.id)
              .toList(growable: false);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _deleting.remove(doc.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final dialogWidth = size.width.clamp(640.0, 1040.0);
    final dialogHeight = size.height.clamp(520.0, 820.0);
    return Dialog(
      backgroundColor: _bg,
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _border),
      ),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            _buildFilterBar(),
            _buildSearchRow(),
            const Divider(height: 1, color: _border),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
      child: Row(
        children: [
          const Icon(Icons.list_alt_outlined, color: _accent, size: 20),
          const SizedBox(width: 8),
          const Text(
            '문서 목록 (학습앱 동기화)',
            style: TextStyle(
              color: _text,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '총 ${_filteredDocuments.length}건',
            style: const TextStyle(
              color: _textSub,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '새로고침',
            onPressed: _isLoading ? null : _reload,
            icon: const Icon(Icons.refresh, color: _textSub, size: 20),
          ),
          IconButton(
            tooltip: '닫기',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, color: _textSub, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '범위 선택',
            style: TextStyle(
              color: _text,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _labeled(
                '교육과정',
                SizedBox(
                  width: 220,
                  child: _dropdown<String>(
                    value: _selectedCurriculumCode,
                    items: widget.curriculumLabels.entries
                        .map(
                          (e) => DropdownMenuItem<String>(
                            value: e.key,
                            child: Text(e.value,
                                overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _isLoading
                        ? null
                        : (v) {
                            if (v == null || v == _selectedCurriculumCode) {
                              return;
                            }
                            _selectedCurriculumCode = v;
                            _reload();
                          },
                  ),
                ),
              ),
              _labeled(
                '초중고',
                Wrap(
                  spacing: 4,
                  children: [
                    for (final lv in _levelOptions)
                      _levelChip(
                        lv,
                        selected: _selectedSchoolLevel == lv,
                        onTap: _isLoading
                            ? null
                            : () {
                                if (_selectedSchoolLevel == lv) return;
                                setState(() => _selectedSchoolLevel = lv);
                                _reload();
                              },
                      ),
                  ],
                ),
              ),
              _labeled(
                '세부 과정',
                SizedBox(
                  width: 180,
                  child: _dropdown<String>(
                    value: _detailedCourseOptions
                            .contains(_selectedDetailedCourse)
                        ? _selectedDetailedCourse
                        : '전체',
                    items: _detailedCourseOptions
                        .map(
                          (c) => DropdownMenuItem<String>(
                            value: c,
                            child: Text(c, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _isLoading
                        ? null
                        : (v) {
                            if (v == null || v == _selectedDetailedCourse) {
                              return;
                            }
                            _selectedDetailedCourse = v;
                            _reload();
                          },
                  ),
                ),
              ),
              _labeled(
                '출처',
                SizedBox(
                  width: 180,
                  child: _dropdown<String>(
                    value: widget.sourceTypeLabels
                            .containsKey(_selectedSourceTypeCode)
                        ? _selectedSourceTypeCode
                        : (widget.sourceTypeLabels.keys.isNotEmpty
                            ? widget.sourceTypeLabels.keys.first
                            : _selectedSourceTypeCode),
                    items: widget.sourceTypeLabels.entries
                        .map(
                          (e) => DropdownMenuItem<String>(
                            value: e.key,
                            child: Text(e.value,
                                overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _isLoading
                        ? null
                        : (v) {
                            if (v == null || v == _selectedSourceTypeCode) {
                              return;
                            }
                            _selectedSourceTypeCode = v;
                            _reload();
                          },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(color: _text, fontSize: 13),
        cursorColor: _accent,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: '파일명 / 학교 / 학년 / 과정 검색',
          hintStyle: const TextStyle(color: _textSub),
          filled: true,
          fillColor: _field,
          prefixIcon: const Icon(Icons.search, color: _textSub, size: 18),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.clear, color: _textSub, size: 16),
                ),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _accent),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: _accent, strokeWidth: 2),
      );
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorMessage!,
            style: const TextStyle(color: Color(0xFFDE6A73)),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final docs = _filteredDocuments;
    if (docs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '조건에 맞는 추출 문서가 없습니다.',
            style: TextStyle(color: _textSub, height: 1.4),
          ),
        ),
      );
    }
    if (_selectedSourceTypeCode == 'school_past') {
      return _buildSchoolPastTree(docs);
    }
    return _buildFlatList(docs);
  }

  Widget _buildFlatList(List<ProblemBankDocument> docs) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: docs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) => _buildDocRow(docs[i]),
    );
  }

  Widget _buildSchoolPastTree(List<ProblemBankDocument> docs) {
    final grouped = <String, Map<String, List<ProblemBankDocument>>>{};
    for (final d in docs) {
      final school = _schoolLabel(d);
      final year = _yearLabel(d);
      grouped.putIfAbsent(school, () => {});
      grouped[school]!.putIfAbsent(year, () => []);
      grouped[school]![year]!.add(d);
    }
    final schools = grouped.keys.toList()
      ..sort((a, b) {
        if (a == _unspecifiedSchool && b != _unspecifiedSchool) return 1;
        if (b == _unspecifiedSchool && a != _unspecifiedSchool) return -1;
        return a.compareTo(b);
      });
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: schools.length,
      itemBuilder: (_, si) {
        final school = schools[si];
        final byYear = grouped[school]!;
        final years = byYear.keys.toList()
          ..sort((a, b) {
            if (a == '미지정' && b != '미지정') return 1;
            if (b == '미지정' && a != '미지정') return -1;
            final ia = int.tryParse(a);
            final ib = int.tryParse(b);
            if (ia != null && ib != null) return ib.compareTo(ia);
            return b.compareTo(a);
          });
        final open = _expandedSchools.contains(school);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionHeader(
              title: school,
              expanded: open,
              onTap: () => setState(() {
                if (open) {
                  _expandedSchools.remove(school);
                } else {
                  _expandedSchools.add(school);
                }
              }),
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final y in years)
                      _buildYearBucket(school, y, byYear[y]!),
                  ],
                ),
              ),
            const SizedBox(height: 4),
          ],
        );
      },
    );
  }

  Widget _buildYearBucket(
    String school,
    String yearLabel,
    List<ProblemBankDocument> docs,
  ) {
    final key = '$school|$yearLabel';
    final open = _expandedYearBuckets.contains(key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          title: yearLabel == '미지정' ? '연도 미지정' : '$yearLabel년',
          dense: true,
          expanded: open,
          onTap: () => setState(() {
            if (open) {
              _expandedYearBuckets.remove(key);
            } else {
              _expandedYearBuckets.add(key);
            }
          }),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final d in docs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _buildDocRow(d),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDocRow(ProblemBankDocument doc) {
    final selected = widget.initialSelectedDocumentId == doc.id;
    final isDeleting = _deleting.contains(doc.id);
    return _HoverableDocRow(
      tooltip: doc.sourceFilename,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: isDeleting ? null : () => Navigator.of(context).pop(doc.id),
        child: Ink(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF173C36)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? const Color(0xFF2B6B61)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.picture_as_pdf_outlined
                    : Icons.description_outlined,
                size: 18,
                color: selected
                    ? const Color(0xFFBEE7D2)
                    : const Color(0xFF8AA5A5),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doc.sourceFilename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFFD6ECEA)
                            : _text,
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _buildSubtitle(doc),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _textSub,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _deleteButton(doc, isDeleting: isDeleting),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deleteButton(ProblemBankDocument doc, {required bool isDeleting}) {
    return Tooltip(
      message: '문서 하드삭제',
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: isDeleting ? null : () => unawaited(_handleDelete(doc)),
            child: Center(
              child: isDeleting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFFDE6A73),
                      ),
                    )
                  : const Icon(
                      Icons.close,
                      size: 16,
                      color: Color(0xFFDE6A73),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader({
    required String title,
    required bool expanded,
    required VoidCallback onTap,
    bool dense = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 8,
            vertical: dense ? 6 : 8,
          ),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: dense ? 18 : 20,
                color: const Color(0xFF8AA5A5),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB8C9C9),
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _labeled(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: _textSub,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }

  Widget _dropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?>? onChanged,
  }) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: _field,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          isDense: true,
          isExpanded: true,
          dropdownColor: _panel,
          style: const TextStyle(color: _text, fontSize: 13),
          iconEnabledColor: _textSub,
        ),
      ),
    );
  }

  Widget _levelChip(String label,
      {required bool selected, required VoidCallback? onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF173C36) : _field,
          border: Border.all(
            color: selected ? const Color(0xFF2E7C70) : _border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFFBEE7D2) : _textSub,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
          ),
        ),
      ),
    );
  }

  static String _schoolLabel(ProblemBankDocument d) {
    final s = d.schoolName.trim();
    return s.isEmpty ? _unspecifiedSchool : s;
  }

  static String _yearLabel(ProblemBankDocument d) {
    final y = d.examYear;
    return y != null && y > 0 ? '$y' : '미지정';
  }

  String _buildSubtitle(ProblemBankDocument d) {
    final parts = <String>[];
    if (d.courseLabel.isNotEmpty) parts.add(d.courseLabel);
    if (d.gradeLabel.isNotEmpty) parts.add(d.gradeLabel);
    if (d.schoolName.isNotEmpty) parts.add(d.schoolName);
    if (d.examYear != null && d.examYear! > 0) parts.add('${d.examYear}');
    if (d.semesterLabel.isNotEmpty) parts.add(d.semesterLabel);
    if (d.examTermLabel.isNotEmpty) parts.add(d.examTermLabel);
    return parts.join(' · ');
  }
}

/// Hover 시 전체 파일명을 툴팁으로 표시하기 위한 래퍼.
class _HoverableDocRow extends StatelessWidget {
  const _HoverableDocRow({required this.tooltip, required this.child});

  final String tooltip;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      preferBelow: false,
      child: child,
    );
  }
}
