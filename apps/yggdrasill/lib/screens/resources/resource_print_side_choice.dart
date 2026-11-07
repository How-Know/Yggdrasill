import 'package:flutter/material.dart';

import '../../services/print_routing_service.dart';
import '../../widgets/dialog_tokens.dart';

/// 자료 인쇄의 양면·단면. 기본은 양면(긴 쪽).
class ResourcePrintSideChoice extends StatelessWidget {
  const ResourcePrintSideChoice({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final PrintDuplexMode mode;
  final ValueChanged<PrintDuplexMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '인쇄 면',
          style: TextStyle(
            color: kDlgTextSub,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _chip(
              label: '양면',
              selected: mode == PrintDuplexMode.twoSidedLongEdge,
              onSelected: () => onChanged(PrintDuplexMode.twoSidedLongEdge),
            ),
            const SizedBox(width: 8),
            _chip(
              label: '단면',
              selected: mode == PrintDuplexMode.oneSided,
              onSelected: () => onChanged(PrintDuplexMode.oneSided),
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      selectedColor: kDlgAccent,
      backgroundColor: kDlgPanelBg,
      labelStyle: TextStyle(
        color: selected ? Colors.white : kDlgText,
        fontWeight: FontWeight.w700,
        decoration: TextDecoration.none,
      ),
      side: BorderSide(color: selected ? kDlgAccent : kDlgBorder),
    );
  }
}
