import 'package:flutter/material.dart';

import '../problem_bank_models.dart';

/// "이번 수정의 의도" 를 검수자에게 묻는 간단한 체크박스 + 메모 다이얼로그.
///
/// 이 다이얼로그의 결과는 `pb_question_revisions` 행에 `reason_tags` / `reason_note`
/// 로 덧붙여 저장돼 이후 학습 데이터로 쓰인다. 따라서:
///   * 체크박스 선택은 가볍게, 15개 태그를 그리드 형태로 한 번에 훑어볼 수 있게.
///   * `other` 를 고르면 메모가 필수. 나머지는 메모 옵션.
///   * 취소 시 null 을 반환. 확인 시 결과 객체 반환.
class QuestionRevisionReasonDialog extends StatefulWidget {
  const QuestionRevisionReasonDialog({
    super.key,
    this.initialTags = const <ProblemBankRevisionReasonTag>[],
    this.initialNote = '',
    this.editedFields = const <String>[],
  });

  final List<ProblemBankRevisionReasonTag> initialTags;
  final String initialNote;

  /// DB trigger 가 기록한 `edited_fields`. 사용자에게 "어떤 필드가 변경됐는지"
  /// 를 상기시켜 태그 선택을 돕는다.
  final List<String> editedFields;

  static Future<QuestionRevisionReasonResult?> show(
    BuildContext context, {
    List<ProblemBankRevisionReasonTag> initialTags = const [],
    String initialNote = '',
    List<String> editedFields = const [],
  }) {
    return showDialog<QuestionRevisionReasonResult>(
      context: context,
      barrierDismissible: true,
      builder: (_) => QuestionRevisionReasonDialog(
        initialTags: initialTags,
        initialNote: initialNote,
        editedFields: editedFields,
      ),
    );
  }

  @override
  State<QuestionRevisionReasonDialog> createState() =>
      _QuestionRevisionReasonDialogState();
}

class _QuestionRevisionReasonDialogState
    extends State<QuestionRevisionReasonDialog> {
  late final Set<ProblemBankRevisionReasonTag> _selected;
  late final TextEditingController _noteCtl;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialTags.toSet();
    _noteCtl = TextEditingController(text: widget.initialNote);
  }

  @override
  void dispose() {
    _noteCtl.dispose();
    super.dispose();
  }

  bool get _needsNote =>
      _selected.contains(ProblemBankRevisionReasonTag.other);

  bool get _canSubmit {
    if (_needsNote && _noteCtl.text.trim().isEmpty) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = ProblemBankRevisionReasonTag.values;
    return AlertDialog(
      backgroundColor: const Color(0xFF10171A),
      title: const Text(
        '수정 의도 태그',
        style: TextStyle(color: Color(0xFFEAF2F2)),
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.editedFields.isNotEmpty) ...[
              Text(
                '자동 감지된 변경 필드: ${widget.editedFields.join(", ")}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF9FB3B3),
                ),
              ),
              const SizedBox(height: 4),
            ],
            const Text(
              '여러 태그를 선택할 수 있습니다. 나중에 오류 패턴 분석과 프롬프트 개선 근거로 쓰입니다.',
              style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: tags.map((t) {
                final selected = _selected.contains(t);
                return FilterChip(
                  label: Text(t.label),
                  selected: selected,
                  showCheckmark: true,
                  onSelected: (v) {
                    setState(() {
                      if (v) {
                        _selected.add(t);
                      } else {
                        _selected.remove(t);
                      }
                    });
                  },
                  backgroundColor: const Color(0xFF15171C),
                  selectedColor: const Color(0xFF33A373),
                  labelStyle: TextStyle(
                    color: selected
                        ? const Color(0xFF0B1112)
                        : const Color(0xFFEAF2F2),
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  side: const BorderSide(color: Color(0xFF223131)),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Text(
              _needsNote ? '메모 (필수)' : '메모 (선택)',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFEAF2F2),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _noteCtl,
              maxLines: 3,
              style: const TextStyle(color: Color(0xFFEAF2F2)),
              decoration: InputDecoration(
                hintText: _needsNote
                    ? '"기타" 선택 시 간단한 설명을 입력해 주세요.'
                    : '필요하면 자유롭게 기록 (예: VLM 이 세트형을 세트로 인식 못함)',
                hintStyle: const TextStyle(color: Color(0xFF647878)),
                filled: true,
                fillColor: const Color(0xFF15171C),
                enabledBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: Color(0xFF223131)),
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: Color(0xFF33A373)),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('취소', style: TextStyle(color: Color(0xFF9FB3B3))),
        ),
        FilledButton(
          onPressed: _canSubmit
              ? () {
                  Navigator.of(context).pop(
                    QuestionRevisionReasonResult(
                      tags: _selected.toList(growable: false),
                      note: _noteCtl.text.trim(),
                    ),
                  );
                }
              : null,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF33A373),
            foregroundColor: const Color(0xFF0B1112),
          ),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class QuestionRevisionReasonResult {
  const QuestionRevisionReasonResult({
    required this.tags,
    required this.note,
  });

  final List<ProblemBankRevisionReasonTag> tags;
  final String note;
}
