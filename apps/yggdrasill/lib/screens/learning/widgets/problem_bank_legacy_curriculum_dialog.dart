import 'package:flutter/material.dart';

import '../models/problem_bank_curriculum_filter.dart';

const Color _kCheckboxBorder = Color(0xFF5E7777);
const Color _kCheckboxActive = Color(0xFF1A6B5E);

Future<Set<String>?> showProblemBankLegacyCurriculumDialog({
  required BuildContext context,
  required Set<String> initialSelected,
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (ctx) {
      var selected = Set<String>.from(initialSelected);
      return StatefulBuilder(
        builder: (ctx, setLocalState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF151C21),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0xFF333333)),
            ),
            title: const Text(
              '이전 교육과정 선택',
              style: TextStyle(
                color: Color(0xFFEAF2F2),
                fontWeight: FontWeight.w800,
              ),
            ),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '포함할 교육과정을 선택하세요.',
                    style: TextStyle(
                      color: Color(0xFF9FB3B3),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final code
                      in ProblemBankCurriculumFilter.legacyCodesOrdered)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () {
                        setLocalState(() {
                          if (selected.contains(code)) {
                            selected.remove(code);
                          } else {
                            selected.add(code);
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Checkbox(
                              value: selected.contains(code),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              side: const BorderSide(color: _kCheckboxBorder),
                              activeColor: _kCheckboxActive,
                              onChanged: (checked) {
                                setLocalState(() {
                                  if (checked == true) {
                                    selected.add(code);
                                  } else {
                                    selected.remove(code);
                                  }
                                });
                              },
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Text(
                                  ProblemBankCurriculumFilter.labels[code] ??
                                      code,
                                  style: TextStyle(
                                    color: selected.contains(code)
                                        ? const Color(0xFFD6ECEA)
                                        : const Color(0xFF8FAAAA),
                                    fontWeight: selected.contains(code)
                                        ? FontWeight.w800
                                        : FontWeight.w700,
                                    fontSize: 12,
                                    height: 1.25,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF9FB3B3),
                ),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(selected),
                style: FilledButton.styleFrom(
                  backgroundColor: _kCheckboxActive,
                ),
                child: const Text('적용'),
              ),
            ],
          );
        },
      );
    },
  );
}
