import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';

/// 왼쪽 패널: 내신 기출(`school_past`)은 학교 → 연도 → 문서, 그 외 출처는 평면 목록.
class ProblemBankSchoolSheet extends StatefulWidget {
  const ProblemBankSchoolSheet({
    super.key,
    required this.sidebarRevision,
    required this.selectedSourceTypeCode,
    required this.documents,
    required this.selectedDocumentId,
    required this.onDocumentSelected,
    required this.isLoading,
  });

  /// 필터 등으로 문서 목록이 갱신될 때마다 증가 — 펼침 상태 초기화용.
  final int sidebarRevision;
  final String selectedSourceTypeCode;
  final List<LearningProblemDocumentSummary> documents;
  final String? selectedDocumentId;
  final ValueChanged<String> onDocumentSelected;
  final bool isLoading;

  @override
  State<ProblemBankSchoolSheet> createState() => _ProblemBankSchoolSheetState();
}

class _ProblemBankSchoolSheetState extends State<ProblemBankSchoolSheet> {
  static const _panelBg = Color(0xFF222222);
  static const _border = Color(0xFF333333);
  static const _selectedBg = Color(0xFF173C36);
  static const _text = Color(0xFFEAF2F2);

  static const _unspecifiedSchool = '학교 미지정';

  final Set<String> _expandedSchools = <String>{};
  final Set<String> _expandedYearBuckets = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _expandForSelectedDocument();
    });
  }

  @override
  void didUpdateWidget(covariant ProblemBankSchoolSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sidebarRevision != widget.sidebarRevision) {
      _expandedSchools.clear();
      _expandedYearBuckets.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expandForSelectedDocument();
      });
    } else if (oldWidget.selectedDocumentId != widget.selectedDocumentId ||
        oldWidget.documents != widget.documents) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expandForSelectedDocument();
      });
    }
  }

  void _expandForSelectedDocument() {
    final id = widget.selectedDocumentId?.trim();
    if (id == null || id.isEmpty) return;
    for (final doc in widget.documents) {
      if (doc.id != id) continue;
      final school = _schoolLabel(doc);
      final yearLabel = _yearLabel(doc);
      final yearKey = '$school|$yearLabel';
      setState(() {
        _expandedSchools.add(school);
        _expandedYearBuckets.add(yearKey);
      });
      return;
    }
  }

  static String _schoolLabel(LearningProblemDocumentSummary d) {
    final s = d.schoolName.trim();
    return s.isEmpty ? _unspecifiedSchool : s;
  }

  static String _yearLabel(LearningProblemDocumentSummary d) {
    final y = d.examYear;
    return y != null ? '$y' : '미지정';
  }

  static Map<String, Map<String, List<LearningProblemDocumentSummary>>>
      _groupBySchoolThenYear(List<LearningProblemDocumentSummary> docs) {
    final out =
        <String, Map<String, List<LearningProblemDocumentSummary>>>{};
    for (final d in docs) {
      final school = _schoolLabel(d);
      final year = _yearLabel(d);
      out.putIfAbsent(school, () => {});
      out[school]!.putIfAbsent(year, () => []);
      out[school]![year]!.add(d);
    }
    return out;
  }

  static List<String> _sortedSchools(Iterable<String> schools) {
    final list = schools.toList();
    list.sort((a, b) {
      if (a == _unspecifiedSchool && b != _unspecifiedSchool) return 1;
      if (b == _unspecifiedSchool && a != _unspecifiedSchool) return -1;
      return a.compareTo(b);
    });
    return list;
  }

  static List<String> _sortedYears(Iterable<String> years) {
    final list = years.toList();
    list.sort((a, b) {
      if (a == '미지정' && b != '미지정') return 1;
      if (b == '미지정' && a != '미지정') return -1;
      final ia = int.tryParse(a);
      final ib = int.tryParse(b);
      if (ia != null && ib != null) return ib.compareTo(ia);
      return b.compareTo(a);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _panelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: _border),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '추출 문서',
                  style: TextStyle(
                    color: _text,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                if (widget.selectedSourceTypeCode != 'school_past') ...[
                  const SizedBox(height: 6),
                  Text(
                    '학교·연도 폴더는 내신 기출 출처에서만 사용됩니다.',
                    style: TextStyle(
                      color: const Color(0xFF9FB3B3).withOpacity(0.95),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _buildBody(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (widget.documents.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '조건에 맞는 추출 문서가 없습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF9FB3B3),
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
      );
    }
    if (widget.selectedSourceTypeCode == 'school_past') {
      return _buildSchoolPastTree(context);
    }
    return _buildFlatList(context);
  }

  Widget _buildFlatList(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      itemCount: widget.documents.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        return _buildDocTile(widget.documents[index]);
      },
    );
  }

  Widget _buildSchoolPastTree(BuildContext context) {
    final grouped = _groupBySchoolThenYear(widget.documents);
    final schools = _sortedSchools(grouped.keys);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      itemCount: schools.length,
      itemBuilder: (context, si) {
        final school = schools[si];
        final byYear = grouped[school]!;
        final years = _sortedYears(byYear.keys);
        final schoolOpen = _expandedSchools.contains(school);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionHeader(
              title: school,
              expanded: schoolOpen,
              onTap: () {
                setState(() {
                  if (schoolOpen) {
                    _expandedSchools.remove(school);
                  } else {
                    _expandedSchools.add(school);
                  }
                });
              },
            ),
            if (schoolOpen)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final year in years)
                      _buildYearSection(
                        school: school,
                        yearLabel: year,
                        docs: byYear[year]!,
                      ),
                  ],
                ),
              ),
            if (si < schools.length - 1) const SizedBox(height: 4),
          ],
        );
      },
    );
  }

  Widget _buildYearSection({
    required String school,
    required String yearLabel,
    required List<LearningProblemDocumentSummary> docs,
  }) {
    final yearKey = '$school|$yearLabel';
    final yearOpen = _expandedYearBuckets.contains(yearKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          title: yearLabel == '미지정' ? '연도 미지정' : '$yearLabel년',
          dense: true,
          expanded: yearOpen,
          onTap: () {
            setState(() {
              if (yearOpen) {
                _expandedYearBuckets.remove(yearKey);
              } else {
                _expandedYearBuckets.add(yearKey);
              }
            });
          },
        ),
        if (yearOpen)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final doc in docs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _buildDocTile(doc),
                  ),
              ],
            ),
          ),
      ],
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
                    fontSize: 15,
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

  Widget _buildDocTile(LearningProblemDocumentSummary doc) {
    final selected = doc.id == widget.selectedDocumentId;
    final subtitle = doc.displaySubtitle;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => widget.onDocumentSelected(doc.id),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _selectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF2B6B61) : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                selected
                    ? Icons.picture_as_pdf_outlined
                    : Icons.description_outlined,
                color: selected
                    ? const Color(0xFFBEE7D2)
                    : const Color(0xFF8AA5A5),
                size: 20,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doc.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFFD6ECEA)
                          : const Color(0xFF9FB3B3),
                      fontWeight:
                          selected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 13,
                      height: 1.25,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFF8FB8B5)
                            : const Color(0xFF7A8F8F),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
