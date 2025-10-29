import 'package:flutter/material.dart';

import 'concept_group.dart';

class SectionList extends StatefulWidget {
  final String chapterId;
  final List<Map<String, dynamic>> sections;
  final String? expandedSectionId;
  final List<Map<String, dynamic>> conceptGroups;
  final Map<String, List<Map<String, dynamic>>> conceptsCache;
  final String? expandedGroupId;

  final void Function(int oldIndex, int newIndex) onReorderSections;
  final void Function(String sectionId) onTapSection;
  final void Function(String sectionId) onAddConceptGroup;
  final void Function(Map<String, dynamic> section, String chapterId) onSectionContextMenu;

  final void Function(String groupId) onAddConcept;
  final void Function(Map<String, dynamic> group, String sectionId) onGroupContextMenu;
  final void Function(String groupId, int oldIndex, int newIndex) onReorderConcepts;
  final void Function(Map<String, dynamic> concept, String groupId) onConceptContextMenu;
  final void Function(String groupId) onToggleNotes;
  final void Function(double relativeOffset)? onArrowPositionMeasured;
  final void Function(Map<String, dynamic> group)? onAddNoteGroup;

  const SectionList({
    super.key,
    required this.chapterId,
    required this.sections,
    required this.expandedSectionId,
    required this.conceptGroups,
    required this.conceptsCache,
    required this.expandedGroupId,
    required this.onReorderSections,
    required this.onTapSection,
    required this.onAddConceptGroup,
    required this.onSectionContextMenu,
    required this.onAddConcept,
    required this.onGroupContextMenu,
    required this.onReorderConcepts,
    required this.onConceptContextMenu,
    required this.onToggleNotes,
    this.onArrowPositionMeasured,
    this.onAddNoteGroup,
  });

  @override
  State<SectionList> createState() => _SectionListState();
}

class _SectionListState extends State<SectionList> {
  final GlobalKey _containerKey = GlobalKey();

  void _handleArrowPositionMeasured(double arrowAbsoluteY) {
    final RenderBox? box = _containerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && widget.onArrowPositionMeasured != null) {
      final containerPosition = box.localToGlobal(Offset.zero);
      final containerCenterY = containerPosition.dy + (box.size.height / 2);
      
      // 상대 오프셋 = 화살표 위치 - 컨테이너 중앙
      final relativeOffset = arrowAbsoluteY - containerCenterY;
      
      widget.onArrowPositionMeasured!(relativeOffset);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: _containerKey,
      width: 518,
      constraints: const BoxConstraints(
        minHeight: 200,
        maxHeight: 864,
      ),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
      ),
      child: widget.sections.isEmpty
          ? Center(
              child: Text(
                '소단원이 없습니다\n대단원을 더블클릭하여 추가하세요',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.3),
                  fontSize: 17,
                ),
              ),
            )
          : ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: widget.sections.length,
              onReorder: (oldIndex, newIndex) => widget.onReorderSections(oldIndex, newIndex),
              itemBuilder: (context, index) {
                final section = widget.sections[index];
                final sectionId = section['id'] as String;
                final isSectionExpanded = widget.expandedSectionId == sectionId;

                return Column(
                  key: ValueKey(sectionId),
                  children: [
                    ReorderableDelayedDragStartListener(
                      index: index,
                      child: GestureDetector(
                        onTap: () => widget.onTapSection(sectionId),
                        onDoubleTap: () => widget.onAddConceptGroup(sectionId),
                        onSecondaryTap: () => widget.onSectionContextMenu(section, widget.chapterId),
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                '${index + 1}.',
                                style: const TextStyle(
                                  color: Color(0xFF999999),
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  section['name'] as String,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                  ),
                                ),
                              ),
                              if (isSectionExpanded)
                                const Icon(
                                  Icons.expand_more,
                                  color: Colors.white54,
                                  size: 20,
                                )
                              else
                                const Icon(
                                  Icons.chevron_right,
                                  color: Colors.white54,
                                  size: 20,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    if (isSectionExpanded)
                      _buildConceptsArea(sectionId),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildConceptsArea(String sectionId) {
    return Container(
      margin: const EdgeInsets.only(left: 20, top: 8, bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: widget.conceptGroups.isEmpty
          ? Center(
              child: Text(
                '더블클릭하여 구분선 추가',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.3),
                  fontSize: 14,
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.conceptGroups.asMap().entries.map((entry) {
                final groupIndex = entry.key;
                final group = entry.value;
                final groupId = group['id'] as String;
                final concepts = widget.conceptsCache[groupId] ?? const <Map<String, dynamic>>[];

                return ConceptGroup(
                  group: group,
                  groupNumber: groupIndex + 1,
                  sectionId: sectionId,
                  concepts: concepts,
                  onAddConcept: widget.onAddConcept,
                  onShowContextMenu: widget.onGroupContextMenu,
                  onReorder: widget.onReorderConcepts,
                  onConceptContextMenu: widget.onConceptContextMenu,
                  isNotesExpanded: widget.expandedGroupId == groupId,
                  onToggleNotes: () => widget.onToggleNotes(groupId),
                  onArrowPositionMeasured: _handleArrowPositionMeasured,
                  onAddNoteGroup: widget.onAddNoteGroup != null 
                      ? () => widget.onAddNoteGroup!(group) 
                      : null,
                );
              }).toList(),
            ),
    );
  }
}


