import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/data_manager.dart';
import '../../services/homework_store.dart';
import '../dialog_tokens.dart';

class FavoriteTemplatesPanel extends StatefulWidget {
  const FavoriteTemplatesPanel({
    super.key,
    required this.containerWidth,
  });

  final double containerWidth;

  @override
  State<FavoriteTemplatesPanel> createState() => _FavoriteTemplatesPanelState();
}

class _FavoriteTemplatesPanelState extends State<FavoriteTemplatesPanel> {
  bool _loading = false;
  String _bookFilter = '';
  String _gradeFilter = '';
  List<HomeworkRecentTemplate> _templates = const [];
  Map<String, String> _bookNameById = const <String, String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_refreshTemplates());
  }

  Future<void> _refreshTemplates() async {
    if (_loading) return;
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      final templates =
          await HomeworkStore.instance.loadRecentTemplates(limit: 120);
      Map<String, String> bookNameById = _bookNameById;
      final requiredBookIds = templates
          .map((e) => e.primaryBookId)
          .where((id) => id.trim().isNotEmpty)
          .toSet();
      final missingBookIds = requiredBookIds
          .where((id) => !bookNameById.containsKey(id))
          .toList(growable: false);
      if (bookNameById.isEmpty || missingBookIds.isNotEmpty) {
        final rows = await DataManager.instance.loadTextbooksWithMetadata();
        final merged = <String, String>{...bookNameById};
        for (final row in rows) {
          final id = '${row['book_id'] ?? ''}'.trim();
          if (id.isEmpty) continue;
          final name = '${row['book_name'] ?? ''}'.trim();
          if (name.isEmpty) continue;
          merged[id] = name;
        }
        bookNameById = merged;
      }
      if (!mounted) return;
      final hasBookFilter = _bookFilter.isNotEmpty &&
          templates.any((t) => t.primaryBookId == _bookFilter);
      final hasGradeFilter = _gradeFilter.isNotEmpty &&
          templates.any((t) => t.primaryGradeLabel == _gradeFilter);
      setState(() {
        _templates = templates;
        _bookNameById = bookNameById;
        if (!hasBookFilter) _bookFilter = '';
        if (!hasGradeFilter) _gradeFilter = '';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _bookName(String bookId) {
    final key = bookId.trim();
    if (key.isEmpty) return '교재 없음';
    final named = (_bookNameById[key] ?? '').trim();
    if (named.isNotEmpty) return named;
    return key;
  }

  List<HomeworkRecentTemplate> _filteredTemplates() {
    final out = <HomeworkRecentTemplate>[];
    for (final template in _templates) {
      if (_bookFilter.isNotEmpty && template.primaryBookId != _bookFilter) {
        continue;
      }
      if (_gradeFilter.isNotEmpty &&
          template.primaryGradeLabel != _gradeFilter) {
        continue;
      }
      out.add(template);
    }
    return out;
  }

  String _partTitle(HomeworkRecentTemplatePart part) {
    final title = part.title.trim().isEmpty ? '(제목 없음)' : part.title.trim();
    return title;
  }

  String _partRightMeta(HomeworkRecentTemplatePart part) {
    final rawPage = (part.page ?? '').trim();
    final pageText = rawPage.isEmpty ? 'p.-' : 'p.$rawPage';
    final countText =
        (part.count == null || part.count! <= 0) ? '문항 미지정' : '${part.count}문항';
    return '$pageText · $countText';
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color:
                  selected ? const Color(0x1F33A373) : const Color(0xFF151C1F),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? const Color(0xFF33A373)
                    : const Color(0xFF2F4343),
                width: selected ? 1.2 : 1.0,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFF9FE3C6)
                    : const Color(0xFF9FB3B3),
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTemplateCardSurface(
    HomeworkRecentTemplate template, {
    required double width,
  }) {
    final title =
        template.title.trim().isEmpty ? '(제목 없음)' : template.title.trim();
    final bookId = template.primaryBookId.trim();
    final grade = template.primaryGradeLabel.trim();
    final bookText = bookId.isEmpty ? '교재 없음' : _bookName(bookId);
    final gradeText = grade.isEmpty ? '학년 미지정' : grade;
    final subtitle =
        template.isGroup ? '그룹 과제 · 하위 ${template.partCount}개' : '단일 과제';
    final previewParts = template.parts.take(3).toList(growable: false);
    final moreCount = template.parts.length - previewParts.length;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: const Color(0xFF11181B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A3A3A)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kDlgText,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$bookText · $gradeText',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kDlgTextSub,
              fontSize: 12.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF8FA3A3),
              fontSize: 12.1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < previewParts.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${i + 1}. ${_partTitle(previewParts[i])}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFCAD2C5),
                      fontSize: 12.1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _partRightMeta(previewParts[i]),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9FB3B3),
                    fontSize: 11.8,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
          if (moreCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '+ $moreCount개 더',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF7F8C8C),
                fontSize: 11.8,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTemplateCard(
    HomeworkRecentTemplate template, {
    required double width,
  }) {
    final card = _buildTemplateCardSurface(template, width: width);
    return Draggable<HomeworkRecentTemplate>(
      data: template,
      maxSimultaneousDrags: 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.94,
          child: _buildTemplateCardSurface(
            template,
            width: width,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.34, child: card),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: card,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sheetScale =
        ((widget.containerWidth / 420.0).clamp(0.78, 1.0)).toDouble();
    final filteredTemplates = _filteredTemplates();
    final bookIds = _templates
        .map((e) => e.primaryBookId)
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => _bookName(a).compareTo(_bookName(b)));
    final gradeLabels = _templates
        .map((e) => e.primaryGradeLabel)
        .where((e) => e.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12 * sheetScale,
        12 * sheetScale,
        12 * sheetScale,
        10 * sheetScale,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.star_rounded, size: 18, color: kDlgAccent),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '최근 과제 즐겨찾기',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: kDlgText,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
              SizedBox(
                width: 34,
                height: 34,
                child: IconButton(
                  onPressed:
                      _loading ? null : () => unawaited(_refreshTemplates()),
                  icon: const Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: kDlgTextSub,
                  ),
                  tooltip: '새로고침',
                  padding: EdgeInsets.zero,
                  splashRadius: 18,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '카드를 드래그해 오른쪽 학생 카드에 드롭하세요.',
            style: TextStyle(
              color: Color(0xFF7F8C8C),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  children: [
                    _buildFilterChip(
                      label: '전체 교재',
                      selected: _bookFilter.isEmpty,
                      onTap: () => setState(() => _bookFilter = ''),
                    ),
                    for (final bookId in bookIds)
                      _buildFilterChip(
                        label: _bookName(bookId),
                        selected: _bookFilter == bookId,
                        onTap: () => setState(() => _bookFilter = bookId),
                      ),
                  ],
                ),
                Wrap(
                  children: [
                    _buildFilterChip(
                      label: '전체 학년',
                      selected: _gradeFilter.isEmpty,
                      onTap: () => setState(() => _gradeFilter = ''),
                    ),
                    for (final grade in gradeLabels)
                      _buildFilterChip(
                        label: grade,
                        selected: _gradeFilter == grade,
                        onTap: () => setState(() => _gradeFilter = grade),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth;
                if (_loading) {
                  return const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(kDlgAccent),
                      ),
                    ),
                  );
                }
                if (filteredTemplates.isEmpty) {
                  return const Center(
                    child: Text(
                      '표시할 최근 과제가 없습니다.',
                      style: TextStyle(
                        color: kDlgTextSub,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: filteredTemplates.length,
                  separatorBuilder: (_, __) => SizedBox(height: 8 * sheetScale),
                  itemBuilder: (context, index) {
                    final template = filteredTemplates[index];
                    return _buildTemplateCard(
                      template,
                      width: cardWidth,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
