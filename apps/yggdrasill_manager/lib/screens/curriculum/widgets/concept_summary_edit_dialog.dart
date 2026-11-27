import 'package:flutter/material.dart';

import '../../../services/concept_draft_models.dart';
import '../../../services/concept_service.dart';
import '../../../widgets/math_shortcuts.dart';
import '../../think/think_style.dart';
import 'concept_type_chip.dart';

class ConceptSummaryEdit {
  const ConceptSummaryEdit({required this.name, required this.content, this.typeName});

  final String name;
  final String content;

  /// 이미 있는 개념 유형 이름. 고르지 않으면 null이고 유형은 바꾸지 않는다.
  final String? typeName;
}

class ConceptSummaryEditRequest {
  const ConceptSummaryEditRequest.save(this.edit) : delete = false;
  const ConceptSummaryEditRequest.delete()
      : edit = null,
        delete = true;

  final ConceptSummaryEdit? edit;
  final bool delete;
}

/// 오른쪽 요약에서 개념 이름·본문과, 이미 있는 유형 표기만 고친다.
/// 구분 둘, 기호, 레벨은 두지 않고 새 유형도 만들지 않는다.
Future<ConceptSummaryEditRequest?> showConceptSummaryEditDialog(
  BuildContext context, {
  required ConceptItem concept,
  required List<ConceptTypeInfo> types,
  String? currentType,
  String? impact,
  bool canDelete = true,
}) {
  return showDialog<ConceptSummaryEditRequest>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ConceptSummaryEditDialog(
      concept: concept,
      types: types,
      currentType: currentType,
      impact: impact,
      canDelete: canDelete,
    ),
  );
}

class _ConceptSummaryEditDialog extends StatefulWidget {
  const _ConceptSummaryEditDialog({
    required this.concept,
    required this.types,
    this.currentType,
    this.impact,
    required this.canDelete,
  });

  final ConceptItem concept;
  final List<ConceptTypeInfo> types;
  final String? currentType;
  final String? impact;
  final bool canDelete;

  @override
  State<_ConceptSummaryEditDialog> createState() => _ConceptSummaryEditDialogState();
}

class _ConceptSummaryEditDialogState extends State<_ConceptSummaryEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _content;
  late String? _type;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.concept.name);
    _content = TextEditingController(text: widget.concept.content);
    final current = (widget.currentType ?? '').trim();
    _type = widget.types.any((t) => t.name == current) ? current : null;
  }

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  bool get _canSave => _name.text.trim().isNotEmpty && _content.text.trim().isNotEmpty;

  void _save() {
    if (!_canSave) return;
    Navigator.pop(
      context,
      ConceptSummaryEditRequest.save(
        ConceptSummaryEdit(name: _name.text.trim(), content: _content.text.trim(), typeName: _type),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final impact = (widget.impact ?? '').trim();
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('개념 수정', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (impact.isNotEmpty) ...[
                Container(
                  key: const ValueKey('concept-edit-impact'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: kThinkPanel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kThinkBorder),
                  ),
                  child: Text(impact, style: const TextStyle(color: kThinkSub, fontSize: 13, height: 1.45)),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const ValueKey('concept-edit-name'),
                controller: _name,
                style: const TextStyle(color: kThinkText),
                cursorColor: kThinkAccent,
                decoration: thinkInputDecoration(label: '이름', hint: '개념 이름'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),
              const Text('유형', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (widget.types.isEmpty)
                const Text('유형 목록을 읽지 못했습니다. 이름과 본문만 고칠 수 있습니다.',
                    style: TextStyle(color: kThinkHint, fontSize: 12))
              else
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.types.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => _typeChip(widget.types[i].name),
                  ),
                ),
              const SizedBox(height: 14),
              MathShortcuts.wrap(
                context: context,
                controller: _content,
                child: TextField(
                  key: const ValueKey('concept-edit-body'),
                  controller: _content,
                  minLines: 6,
                  maxLines: 10,
                  style: const TextStyle(color: kThinkText, height: 1.45),
                  cursorColor: kThinkAccent,
                  decoration: thinkInputDecoration(label: '본문', hint: '개념 본문'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.canDelete)
          TextButton(
            key: const ValueKey('concept-edit-delete'),
            onPressed: () => Navigator.pop(context, const ConceptSummaryEditRequest.delete()),
            child: const Text('삭제', style: TextStyle(color: kThinkError, fontWeight: FontWeight.w700)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          key: const ValueKey('concept-edit-save'),
          onPressed: _canSave ? _save : null,
          style: thinkPrimaryButton(),
          child: const Text('저장'),
        ),
      ],
    );
  }

  Widget _typeChip(String name) {
    final on = _type == name;
    final style = conceptTypeStyle(name);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('concept-edit-type-$name'),
        onTap: () => setState(() => _type = name),
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: on ? style.color.withValues(alpha: 0.16) : kThinkPanel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: on ? style.color.withValues(alpha: 0.6) : kThinkBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConceptTypeGlyph(style),
              const SizedBox(width: 6),
              Text(name,
                  style: TextStyle(
                    color: on ? style.foreground : kThinkSub,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
