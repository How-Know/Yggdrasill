import 'package:flutter/material.dart';
import 'dart:convert';

class ConceptGroup extends StatefulWidget {
  final Map<String, dynamic> group;
  final int groupNumber;
  final String sectionId;
  final List<Map<String, dynamic>> concepts;
  final Function(String) onAddConcept;
  final Function(Map<String, dynamic>, String) onShowContextMenu;
  final Function(String, int, int) onReorder;
  final Function(Map<String, dynamic>, String) onConceptContextMenu;
  final bool isNotesExpanded;
  final VoidCallback onToggleNotes;
  final Function(double)? onArrowPositionMeasured;
  final VoidCallback? onAddNoteGroup;
  final Function(Map<String, dynamic>, Map<String, dynamic>)? onAddNote;
  final Function(Map<String, dynamic>, int)? onDeleteNoteGroup;
  final Function(Map<String, dynamic>, int, int)? onDeleteNote;

  const ConceptGroup({
    super.key,
    required this.group,
    required this.groupNumber,
    required this.sectionId,
    required this.concepts,
    required this.onAddConcept,
    required this.onShowContextMenu,
    required this.onReorder,
    required this.onConceptContextMenu,
    required this.isNotesExpanded,
    required this.onToggleNotes,
    this.onArrowPositionMeasured,
    this.onAddNoteGroup,
    this.onAddNote,
    this.onDeleteNoteGroup,
    this.onDeleteNote,
  });

  @override
  State<ConceptGroup> createState() => _ConceptGroupState();
}

class _ConceptGroupState extends State<ConceptGroup> {
  final GlobalKey _arrowKey = GlobalKey();

  void _measureArrowPosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final RenderBox? box = _arrowKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && widget.onArrowPositionMeasured != null) {
        final position = box.localToGlobal(Offset.zero);
        widget.onArrowPositionMeasured!(position.dy);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final groupId = widget.group['id'] as String;
    final groupName = widget.group['name'] as String? ?? '';
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 왼쪽: 구분선 + 개념 칩
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                // 구분선
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 괄호 숫자
                    GestureDetector(
                      onTap: () => widget.onAddConcept(groupId),
                      onLongPress: () => widget.onShowContextMenu(widget.group, widget.sectionId),
                      onSecondaryTap: () => widget.onShowContextMenu(widget.group, widget.sectionId),
                      child: Text(
                        '(${widget.groupNumber})',
                        style: const TextStyle(
                          color: Color(0xFF999999),
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (groupName.isNotEmpty)
                      GestureDetector(
                        onDoubleTap: () {
                          if (widget.onAddNoteGroup != null) {
                            widget.onAddNoteGroup!();
                          }
                        },
                        child: Text(
                          groupName,
                          style: const TextStyle(
                            color: Color(0xFF999999),
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 2,
                        color: const Color(0xFF666666),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 노트 펼치기 버튼
                    GestureDetector(
                      onTap: () {
                        widget.onToggleNotes();
                        _measureArrowPosition();
                      },
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: widget.isNotesExpanded 
                              ? const Color(0xFF4A9EFF).withOpacity(0.2)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          key: _arrowKey,
                          widget.isNotesExpanded ? Icons.chevron_left : Icons.chevron_right,
                          color: widget.isNotesExpanded ? const Color(0xFF4A9EFF) : const Color(0xFF666666),
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 개념 칩들
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: widget.concepts.asMap().entries.map((entry) {
                    final index = entry.key;
                    final concept = entry.value;
                    return _buildDraggableConceptChip(concept, groupId, index);
                  }).toList(),
                ),
              ],
            ),
          ),
          
          // 오른쪽: 노트 영역
          if (widget.isNotesExpanded && widget.onAddNote != null) ...[
            const SizedBox(width: 20),
            Expanded(
              child: _buildNoteArea(),
            ),
          ],
        ],
      ),
      ),
    );
  }
  
  Widget _buildNoteArea() {
    // notes를 JSON으로 파싱 (구분선별 그룹화)
    List<Map<String, dynamic>> noteGroups = [];
    
    final notesData = widget.group['notes'];
    
    if (notesData == null || (notesData is List && notesData.isEmpty)) {
      noteGroups = [];
    } else if (notesData is List && notesData.isNotEmpty) {
      final firstItem = notesData[0];
      
      if (firstItem is String) {
        // JSONB가 JSON 문자열로 반환된 경우
        try {
          noteGroups = notesData.map((item) {
            final parsed = jsonDecode(item as String) as Map<String, dynamic>;
            return {
              'id': parsed['id']?.toString() ?? 'unknown',
              'name': parsed['name']?.toString() ?? '',
              'items': parsed['items'] != null 
                  ? List<String>.from(parsed['items'] as List)
                  : <String>[],
            };
          }).toList();
        } catch (e) {
          noteGroups = [
            {'id': 'default', 'name': '', 'items': <String>[]}
          ];
        }
      } else if (firstItem is Map) {
        noteGroups = notesData.map((item) {
          final itemMap = item as Map;
          return {
            'id': itemMap['id']?.toString() ?? 'unknown',
            'name': itemMap['name']?.toString() ?? '',
            'items': itemMap['items'] != null 
                ? List<String>.from(itemMap['items'] as List)
                : <String>[],
          };
        }).toList();
      }
    }
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: noteGroups.asMap().entries.map((entry) {
          final noteGroupIndex = entry.key;
          final noteGroup = entry.value;
          return _buildNoteGroup(noteGroup, noteGroupIndex + 1);
        }).toList(),
      ),
    );
  }
  
  Widget _buildNoteGroup(Map<String, dynamic> noteGroup, int groupNumber) {
    final items = List<String>.from(noteGroup['items'] as List<dynamic>? ?? []);
    final noteGroupName = noteGroup['name'] as String? ?? '';
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 구분선
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 숫자 버튼 (아웃라인 원형)
              GestureDetector(
                onTap: () {
                  if (widget.onAddNote != null) {
                    widget.onAddNote!(widget.group, noteGroup);
                  }
                },
                onLongPress: () {
                  if (widget.onDeleteNoteGroup != null) {
                    widget.onDeleteNoteGroup!(widget.group, groupNumber - 1);
                  }
                },
                onSecondaryTap: () {
                  if (widget.onDeleteNoteGroup != null) {
                    widget.onDeleteNoteGroup!(widget.group, groupNumber - 1);
                  }
                },
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF666666), width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      '$groupNumber',
                      style: const TextStyle(
                        color: Color(0xFF999999),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (noteGroupName.isNotEmpty)
                Text(
                  noteGroupName,
                  style: const TextStyle(
                    color: Color(0xFF999999),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: 1,
                  color: const Color(0xFF666666),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 노트 항목들
          ...items.asMap().entries.map((entry) {
            final itemIndex = entry.key;
            final item = entry.value;
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item,
                      style: const TextStyle(
                        color: Color(0xFFB3B3B3),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      if (widget.onDeleteNote != null) {
                        widget.onDeleteNote!(widget.group, groupNumber - 1, itemIndex);
                      }
                    },
                    child: const Icon(
                      Icons.close,
                      color: Colors.white54,
                      size: 14,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDraggableConceptChip(Map<String, dynamic> concept, String groupId, int index) {
    final tags = concept['tags'] as List<dynamic>? ?? [];
    final hasDefinition = tags.contains('정의');
    final hasTheorem = tags.contains('정리');
    final chipColor = hasDefinition 
        ? const Color(0xFFFF5252) 
        : (hasTheorem ? const Color(0xFF4A9EFF) : const Color(0xFF999999));
    
    return LongPressDraggable<int>(
      data: index,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: chipColor, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              concept['name'] as String,
              style: TextStyle(
                color: chipColor,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: _buildConceptChip(concept, groupId),
      ),
      child: DragTarget<int>(
        onAcceptWithDetails: (details) {
          widget.onReorder(groupId, details.data, index);
        },
        builder: (context, candidateData, rejectedData) {
          return _buildConceptChip(concept, groupId);
        },
      ),
    );
  }

  Widget _buildConceptChip(Map<String, dynamic> concept, String groupId) {
    final tags = concept['tags'] as List<dynamic>? ?? [];
    final hasDefinition = tags.contains('정의');
    final hasTheorem = tags.contains('정리');
    final chipColor = hasDefinition 
        ? const Color(0xFFFF5252) 
        : (hasTheorem ? const Color(0xFF4A9EFF) : const Color(0xFF999999));
    
    return GestureDetector(
      onSecondaryTap: () => widget.onConceptContextMenu(concept, groupId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: chipColor, width: 1.5),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          concept['name'] as String,
          style: TextStyle(
            color: chipColor,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

