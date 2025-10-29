import 'package:flutter/material.dart';

class ChapterCard extends StatelessWidget {
  final Map<String, dynamic> chapter;
  final bool isExpanded;
  final int sectionCount;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onSecondaryTap;

  const ChapterCard({
    super.key,
    required this.chapter,
    required this.isExpanded,
    required this.sectionCount,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onSecondaryTap: onSecondaryTap,
      child: Container(
        width: 288,
        height: 172,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isExpanded ? const Color(0xFF4A9EFF) : const Color(0xFF3A3A3A),
            width: isExpanded ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    chapter['name'] as String,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(
                  isExpanded ? Icons.chevron_right : Icons.chevron_left,
                  color: Colors.white70,
                  size: 28,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '소단원 $sectionCount개',
              style: const TextStyle(
                color: Color(0xFFB3B3B3),
                fontSize: 17,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


