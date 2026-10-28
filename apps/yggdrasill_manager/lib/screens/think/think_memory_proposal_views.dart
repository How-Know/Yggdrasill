import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/think/think_action_models.dart';
import '../../services/think/think_models.dart';
import 'think_code_views.dart';
import 'think_memory_scope_picker.dart';
import 'think_style.dart';

// 기억 저장 제안 카드의 내용·고치기 창·기능 상태 문구.
// 설계: docs/architecture/ai-think-actions.md §9

String thinkMemoryScopeLabel(ThinkMemoryProposal m) {
  if (m.memoryScope != 'department') return '공통';
  final d = ThinkDepartmentId.parse(m.scopeDepartment);
  return d == null ? '부서' : '${d.label} 부서';
}

const Map<String, String> kThinkMemoryCardOps = {'revise': '수정', 'replace': '새 카드로 대체', 'withdraw': '삭제'};

/// 기억 내용. 빈 항목은 숨기고, 원칙이면 결정 전용 항목(배경·이유·대안)을 보이지 않는다.
class ThinkMemoryProposalView extends StatelessWidget {
  const ThinkMemoryProposalView({super.key, required this.memory, this.showScope = true});

  final ThinkMemoryProposal memory;
  final bool showScope;

  @override
  Widget build(BuildContext context) {
    Widget text(String v) => SelectableText(v, style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ThinkBadge(memory.kindLabel, color: kThinkAccent),
            if (showScope) Text('범위 제안: ${thinkMemoryScopeLabel(memory)}', style: const TextStyle(color: kThinkSub, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(
          memory.title,
          style: const TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800, height: 1.4),
        ),
        thinkCodeLabel(memory.isDecision ? '결정' : '내용'),
        text(memory.content),
        if (memory.isDecision && memory.decisionContext.isNotEmpty) ...[
          thinkCodeLabel('배경'),
          text(memory.decisionContext),
        ],
        if (memory.isDecision && memory.decisionReason.isNotEmpty) ...[
          thinkCodeLabel('이유'),
          text(memory.decisionReason),
        ],
        if (memory.isDecision && memory.alternatives.isNotEmpty) ...[
          thinkCodeLabel('검토한 대안'),
          thinkCodeBullets(memory.alternatives),
        ],
      ],
    );
  }
}

/// 비교 근거. 검색 발췌나 모델이 적은 판이 아니라, 카드에 저장된 조회 기록만 보여 준다.
class ThinkMemoryBasisNote extends StatelessWidget {
  const ThinkMemoryBasisNote({super.key, required this.action});

  final ThinkAction action;

  @override
  Widget build(BuildContext context) {
    if (!action.memoryBasisReady) {
      return const ThinkNotice(
        icon: Icons.warning_amber_outlined,
        text: '비교 근거가 없습니다. 이 카드는 승인할 수 없습니다. 다시 비교해 제안해야 하며, 거절만 할 수 있습니다.',
      );
    }
    final lines = <String>[
      if (action.memoryRelationLabel.isNotEmpty) '비교: ${action.memoryRelationLabel}',
      '검색한 범위만 확인했습니다. 모든 기억과 비교한 것은 아닙니다.',
      if (action.memoryBasisReads.isEmpty) '원문을 비교한 다른 기억은 없습니다.',
      for (final r in action.memoryBasisReads) _readLine(r),
      '위에 적힌 version은 비교할 때 읽은 판입니다.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.45)),
          ),
      ],
    );
  }

  static String _readLine(Map<String, dynamic> r) {
    final title = _s(r['title']);
    final role = _s(r['role']) == 'supersede' ? '대체 대상' : '비교';
    return '$role · ${title.isEmpty ? '(제목 없음)' : title} · version ${_s(r['version'])} · ${_s(r['id'])}';
  }

  static String _s(dynamic v) => v == null ? '' : v.toString().trim();
}

/// 승인 전에 기억 내용·범위를 고친다. 확인하면 고친 내용으로 바로 승인한다(서버가 다시 검사한다).
class ThinkMemoryEditDialog extends StatefulWidget {
  const ThinkMemoryEditDialog({super.key, required this.memory, required this.showScope, required this.confirmLabel});

  final ThinkMemoryProposal memory;
  final bool showScope;
  final String confirmLabel;

  static Future<ThinkMemoryProposal?> show(
    BuildContext context, {
    required ThinkMemoryProposal memory,
    required bool showScope,
    String confirmLabel = '고친 내용으로 저장',
  }) =>
      showDialog<ThinkMemoryProposal>(
        context: context,
        builder: (_) => ThinkMemoryEditDialog(memory: memory, showScope: showScope, confirmLabel: confirmLabel),
      );

  @override
  State<ThinkMemoryEditDialog> createState() => _ThinkMemoryEditDialogState();
}

class _ThinkMemoryEditDialogState extends State<ThinkMemoryEditDialog> {
  late String _kind = widget.memory.kind;
  late final TextEditingController _title = TextEditingController(text: widget.memory.title);
  late final TextEditingController _content = TextEditingController(text: widget.memory.content);
  late final TextEditingController _context = TextEditingController(text: widget.memory.decisionContext);
  late final TextEditingController _reason = TextEditingController(text: widget.memory.decisionReason);
  late final TextEditingController _alternatives = TextEditingController(text: widget.memory.alternatives.join('\n'));
  late ThinkMemoryScope _scope =
      widget.memory.memoryScope == 'department' ? ThinkMemoryScope.department : ThinkMemoryScope.common;
  late ThinkDepartmentId? _department = ThinkDepartmentId.parse(widget.memory.scopeDepartment);

  @override
  void dispose() {
    for (final c in [_title, _content, _context, _reason, _alternatives]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _title.text.trim().isNotEmpty &&
      _content.text.trim().isNotEmpty &&
      (_scope != ThinkMemoryScope.department || _department != null);

  void _submit() {
    if (!_valid) return;
    final department = _scope == ThinkMemoryScope.department;
    Navigator.pop(
      context,
      widget.memory.copyWith(
        kind: _kind,
        title: _title.text.trim(),
        content: _content.text.trim(),
        decisionContext: _context.text.trim(),
        decisionReason: _reason.text.trim(),
        alternatives: [
          for (final raw in _alternatives.text.split('\n'))
            if (raw.trim().isNotEmpty) raw.trim(),
        ],
        memoryScope: department ? 'department' : 'common',
        scopeDepartment: department ? _department?.db : null,
        clearDepartment: !department,
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {int minLines = 1, int maxLines = 4, int? maxLength}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          minLines: minLines,
          maxLines: maxLines,
          inputFormatters: maxLength == null ? null : [LengthLimitingTextInputFormatter(maxLength)],
          style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5),
          decoration: thinkInputDecoration(label: label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final decision = _kind == 'decision';
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Text('기억 내용 고치기', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('종류', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ThinkToggleChip(
                    label: '결정',
                    icon: Icons.gavel_outlined,
                    selected: decision,
                    onChanged: (_) => setState(() => _kind = 'decision'),
                  ),
                  ThinkToggleChip(
                    label: '원칙',
                    icon: Icons.rule,
                    selected: !decision,
                    onChanged: (_) => setState(() => _kind = 'principle'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _field(_title, '제목 (필수)', maxLines: 1, maxLength: 200),
              _field(_content, decision ? '결정 내용 (필수)' : '원칙 내용 (필수)', minLines: 3, maxLines: 8, maxLength: 8000),
              if (decision) ...[
                _field(_context, '배경 (왜 이 문제를 다뤘나)', minLines: 2, maxLines: 6, maxLength: 4000),
                _field(_reason, '이유', minLines: 2, maxLines: 6, maxLength: 4000),
                _field(_alternatives, '검토한 대안 (한 줄에 하나)', minLines: 2, maxLines: 6),
              ],
              if (widget.showScope)
                ThinkMemoryScopePicker(
                  scope: _scope,
                  department: _department,
                  onChanged: (s, d) => setState(() {
                    _scope = s;
                    _department = d;
                  }),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_title, _content]),
          builder: (context, _) => ElevatedButton.icon(
            onPressed: _valid ? _submit : null,
            style: thinkPrimaryButton(),
            icon: const Icon(Icons.check, size: 16),
            label: Text(widget.confirmLabel),
          ),
        ),
      ],
    );
  }
}

String thinkMemoryProposalsFeatureReason(ThinkFeatureStatus f) => switch (f.state) {
      ThinkFeatureState.ready => 'Think가 대화에서 확정된 결론·원칙을 기억 저장 카드로 제안합니다. 승인해야 저장됩니다.',
      ThinkFeatureState.dbRequired =>
        'DB 반영 필요 — 운영 DB에 마이그레이션 20261011100000_ai_think_memory_proposals.sql이 아직 없습니다. 그동안 기억 저장 제안을 하지 않습니다.',
      ThinkFeatureState.appUpdateRequired => '앱 업데이트 필요 — 이 앱이 기억 저장 카드를 처리한다고 알리지 않았습니다.',
      ThinkFeatureState.unknown => '서버가 DB 준비 여부를 확인하지 못했습니다. 확인되기 전에는 쓰지 않습니다.',
      ThinkFeatureState.edgeMissing => 'Edge 배포 필요 — 연결된 ai_think가 기억 저장 제안을 모르는 이전 버전입니다.',
    };
