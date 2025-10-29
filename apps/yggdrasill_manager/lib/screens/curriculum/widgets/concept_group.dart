import 'package:flutter/material.dart';
import 'measure_size.dart';

class ConceptGroup extends StatelessWidget {
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
  final Function(String, double)? onHeightChanged;

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
    this.onHeightChanged,
  });

  @override
  Widget build(BuildContext context) {
    final groupId = group['id'] as String;
    final groupName = group['name'] as String? ?? '';
    
    return MeasureSize(
      onChange: (size) {
        if (onHeightChanged != null) {
          onHeightChanged!(groupId, size.height);
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 구분선
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 괄호 숫자
              GestureDetector(
                onTap: () => onAddConcept(groupId),
                onLongPress: () => onShowContextMenu(group, sectionId),
                onSecondaryTap: () => onShowContextMenu(group, sectionId),
                child: Text(
                  '($groupNumber)',
                  style: const TextStyle(
                    color: Color(0xFF999999),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (groupName.isNotEmpty)
                Text(
                  groupName,
                  style: const TextStyle(
                    color: Color(0xFF999999),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
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
            onTap: onToggleNotes,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isNotesExpanded 
                    ? const Color(0xFF4A9EFF).withOpacity(0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                isNotesExpanded ? Icons.chevron_left : Icons.chevron_right,
                color: isNotesExpanded ? const Color(0xFF4A9EFF) : const Color(0xFF666666),
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
            children: concepts.asMap().entries.map((entry) {
              final index = entry.key;
              final concept = entry.value;
              return _buildDraggableConceptChip(concept, groupId, index);
            }).toList(),
          ),
        ],
      ),
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
          onReorder(groupId, details.data, index);
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
      onSecondaryTap: () => onConceptContextMenu(concept, groupId),
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

