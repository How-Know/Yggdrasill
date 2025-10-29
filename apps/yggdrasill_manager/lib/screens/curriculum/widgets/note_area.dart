import 'package:flutter/material.dart';
import 'dart:convert';

class NoteArea extends StatelessWidget {
  final Map<String, dynamic> group;
  final double topOffset;
  final Function(Map<String, dynamic>) onAddNoteGroup;
  final Function(Map<String, dynamic>, Map<String, dynamic>) onAddNote;
  final Function(Map<String, dynamic>, int) onDeleteNoteGroup;
  final Function(Map<String, dynamic>, int, int) onDeleteNote;

  const NoteArea({
    super.key,
    required this.group,
    required this.topOffset,
    required this.onAddNoteGroup,
    required this.onAddNote,
    required this.onDeleteNoteGroup,
    required this.onDeleteNote,
  });

  @override
  Widget build(BuildContext context) {
    // notes를 JSON으로 파싱 (구분선별 그룹화)
    List<Map<String, dynamic>> noteGroups = [];
    
    final notesData = group['notes'];
    
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
          print('JSON 파싱 실패: $e');
          noteGroups = [
            {'id': 'default', 'name': '', 'items': List<String>.from(notesData)}
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
    
    return Transform.translate(
      offset: Offset(0, topOffset),
      child: Container(
        width: 500,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
          Row(
            children: [
              const Text(
                '정리/명제/공식',
                style: TextStyle(
                  color: Color(0xFF999999),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => onAddNoteGroup(group),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF666666),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.add, color: Colors.white70, size: 20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (noteGroups.isEmpty)
            Center(
              child: Text(
                '+ 버튼을 눌러 구분선 추가',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.3),
                  fontSize: 14,
                ),
              ),
            )
          else
            ...noteGroups.asMap().entries.map((entry) {
              final noteGroupIndex = entry.key;
              final noteGroup = entry.value;
              return _buildNoteGroup(
                context,
                noteGroup,
                noteGroupIndex + 1,
              );
            }),
        ],
      ),
      ),
    );
  }

  Widget _buildNoteGroup(BuildContext context, Map<String, dynamic> noteGroup, int groupNumber) {
    final items = List<String>.from(noteGroup['items'] as List<dynamic>? ?? []);
    final noteGroupName = noteGroup['name'] as String? ?? '';
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 구분선
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 숫자 버튼 (아웃라인 원형)
              GestureDetector(
                onTap: () => onAddNote(group, noteGroup),
                onLongPress: () => onDeleteNoteGroup(group, groupNumber - 1),
                onSecondaryTap: () => onDeleteNoteGroup(group, groupNumber - 1),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF666666), width: 2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      '$groupNumber',
                      style: const TextStyle(
                        color: Color(0xFF999999),
                        fontSize: 13,
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
                    fontSize: 16,
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
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item,
                      style: const TextStyle(
                        color: Color(0xFFB3B3B3),
                        fontSize: 15,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => onDeleteNote(group, groupNumber - 1, itemIndex),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white54,
                      size: 16,
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
}

