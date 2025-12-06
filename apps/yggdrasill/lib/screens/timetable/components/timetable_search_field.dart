import 'package:flutter/material.dart';

class TimetableSearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool hasText;

  const TimetableSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.hasText,
  });

  @override
  Widget build(BuildContext context) {
    const double height = 48;
    const double baseWidth = 280;
    const double width = baseWidth * 0.64;
    return SizedBox(
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(color: Colors.transparent),
        ),
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: [
            const Icon(Icons.search, color: Colors.white70, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  hintText: '검색',
                  hintStyle: TextStyle(color: Colors.white54),
                ),
              ),
            ),
            if (hasText)
              IconButton(
                icon: const Icon(Icons.clear, color: Colors.white54, size: 18),
                splashRadius: 18,
                padding: EdgeInsets.zero,
                onPressed: onClear,
              ),
          ],
        ),
      ),
    );
  }
}

