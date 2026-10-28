import 'package:flutter/material.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_memory_scope_picker.dart';
import 'think_style.dart';

/// 답변 + 운영자 피드백으로 기억 초안 후보를 받고, 항목별로 초안 저장·확정·폐기한다. AI 결과는 자동 active가 되지 않는다.
class ThinkMemoryFeedbackDialog extends StatefulWidget {
  const ThinkMemoryFeedbackDialog({
    super.key,
    required this.conversationId,
    required this.assistantMessageId,
    required this.userMessageIds,
  });

  final String conversationId;
  final String assistantMessageId;
  final List<String> userMessageIds;

  static Future<void> show(
    BuildContext context, {
    required String conversationId,
    required String assistantMessageId,
    required List<String> userMessageIds,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ThinkMemoryFeedbackDialog(
        conversationId: conversationId,
        assistantMessageId: assistantMessageId,
        userMessageIds: userMessageIds,
      ),
    );
  }

  @override
  State<ThinkMemoryFeedbackDialog> createState() => _ThinkMemoryFeedbackDialogState();
}

class _ThinkMemoryFeedbackDialogState extends State<ThinkMemoryFeedbackDialog> {
  final _feedback = TextEditingController();
  String? _updateMemoryId;
  bool _requesting = false;
  String? _error;
  ThinkMemoryFeedbackDraft? _draft;
  final Set<int> _discarded = {};

  /// 후보별로 사람이 고른 범위. 고르지 않았으면 새 기억은 공통, 수정은 기존 기억의 범위.
  final Map<int, (ThinkMemoryScope, ThinkDepartmentId?)> _scopes = {};

  ThinkController get _c => ThinkController.instance;

  (ThinkMemoryScope, ThinkDepartmentId?) _scopeFor(int index, ThinkMemoryFeedbackCandidate c) {
    final picked = _scopes[index];
    if (picked != null) return picked;
    final existing = c.updateMemoryId == null ? null : _c.memoryById(c.updateMemoryId);
    if (existing != null) return (existing.memoryScope, existing.scopeDepartment);
    return (ThinkMemoryScope.common, null);
  }

  /// 이 대화가 지금 열려 있을 때만 그 역할을 제안한다(저장된 역할을 모르는 대화는 제안하지 않는다).
  ThinkRoleId? get _suggestedRole =>
      _c.selectedId == widget.conversationId && _c.conversationRole != ThinkRoleId.lead ? _c.conversationRole : null;

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  Future<void> _requestDraft() async {
    if (_feedback.text.trim().isEmpty) {
      showThinkSnack(context, '피드백을 입력하세요.', error: true);
      return;
    }
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      final res = await ThinkApi.instance.memoryFeedbackDraft(
        conversationId: widget.conversationId,
        assistantMessageId: widget.assistantMessageId,
        userMessageIds: widget.userMessageIds,
        feedback: _feedback.text,
        updateMemoryId: _updateMemoryId,
      );
      if (!mounted) return;
      setState(() {
        _draft = res.draft;
        _discarded.clear();
        _scopes.clear();
        _requesting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ThinkApiException ? e.message : '초안을 만들지 못했습니다: $e';
        _requesting = false;
      });
    }
  }

  Future<void> _saveCandidate(int _, ThinkMemoryStatus __) async {
    showMemoryApprovalOnly(context);
  }

  @override
  Widget build(BuildContext context) {
    final editableMemories = _c.memories
        .where((m) => m.status == ThinkMemoryStatus.active || m.status == ThinkMemoryStatus.draft)
        .toList();
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: const Row(
        children: [
          Icon(Icons.rate_review_outlined, color: kThinkAccent, size: 22),
          SizedBox(width: 12),
          Expanded(
            child: Text('답변 피드백 → 기억 초안', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800, fontSize: 18)),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 560,
        child: _draft == null ? _requestForm(editableMemories) : _candidateList(),
      ),
      actions: [
        TextButton(
          onPressed: _requesting ? null : () => Navigator.pop(context),
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
        if (_draft == null)
          ElevatedButton(
            onPressed: _requesting ? null : _requestDraft,
            style: thinkPrimaryButton(),
            child: _requesting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('초안 요청'),
          ),
      ],
    );
  }

  Widget _requestForm(List<ThinkMemory> editableMemories) {
    if (_error != null) {
      return Center(child: ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline));
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '선택한 답변과 관련 질문, 아래 피드백만 근거로 note·principle·decision 후보를 제안합니다. '
            '승인 전 후보는 AI 대화 맥락에 들어가지 않습니다.',
            style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _feedback,
            minLines: 4,
            maxLines: 8,
            style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
            decoration: thinkInputDecoration(label: '피드백 (무엇을 기억에 남길지)'),
          ),
          if (editableMemories.isNotEmpty) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _updateMemoryId,
              isExpanded: true,
              dropdownColor: kThinkPanel,
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(label: '수정할 기존 기억 (선택)'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('새 기억만 제안')),
                for (final m in editableMemories)
                  DropdownMenuItem<String?>(
                    value: m.id,
                    child: Text('${m.kind.label} · ${m.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _updateMemoryId = v),
            ),
          ],
        ],
      ),
    );
  }

  Widget _candidateList() {
    final draft = _draft!;
    if (draft.insufficientEvidence && draft.candidates.isEmpty) {
      return Center(
        child: ThinkNotice(
          text: draft.notes.isEmpty ? '근거가 부족해 후보를 만들지 않았습니다.' : draft.notes,
          icon: Icons.info_outline,
        ),
      );
    }
    return ListView(
      children: [
        if (draft.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ThinkNotice(text: draft.notes, icon: Icons.info_outline),
          ),
        for (var i = 0; i < draft.candidates.length; i++)
          if (!_discarded.contains(i)) _candidateCard(i, draft.candidates[i], draft.duplicateWarnings),
      ],
    );
  }

  Widget _candidateCard(int index, ThinkMemoryFeedbackCandidate c, List<ThinkMemoryFeedbackDuplicate> dups) {
    final warns = dups.where((d) => d.candidateIndex == index).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${c.kind.label}${c.updateMemoryId != null ? ' (수정)' : ''}',
              style: const TextStyle(color: kThinkAccent, fontSize: 12, fontWeight: FontWeight.w700)),
          if (warns.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ThinkNotice(
                text: warns.map((w) => '· ${w.reason}: ${w.memoryTitle} (id ${w.memoryId})').join('\n'),
                color: kThinkLink,
                icon: Icons.warning_amber_outlined,
              ),
            ),
          const SizedBox(height: 8),
          _editField('제목', c.title, (v) => c.title = v),
          const SizedBox(height: 8),
          _editField('내용', c.content, (v) => c.content = v, lines: 3),
          if (c.kind == ThinkMemoryKind.decision) ...[
            const SizedBox(height: 8),
            _editField('배경', c.decisionContext, (v) => c.decisionContext = v, lines: 2),
            const SizedBox(height: 8),
            _editField('이유', c.decisionReason, (v) => c.decisionReason = v, lines: 2),
          ],
          if (_c.rolesReady) ...[
            const SizedBox(height: 12),
            Builder(builder: (_) {
              final (scope, dept) = _scopeFor(index, c);
              final existing = c.updateMemoryId == null ? null : _c.memoryById(c.updateMemoryId);
              return ThinkMemoryScopePicker(
                scope: scope,
                department: dept,
                showLegacy: existing?.memoryScope == ThinkMemoryScope.legacyUnscoped,
                suggestedRole: _suggestedRole,
                enabled: true,
                onChanged: (s, d) => setState(() => _scopes[index] = (s, d)),
              );
            }),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => setState(() => _discarded.add(index)),
                style: thinkOutlineButton(),
                child: const Text('폐기'),
              ),
              OutlinedButton(
                onPressed: () => _saveCandidate(index, ThinkMemoryStatus.draft),
                style: thinkOutlineButton(),
                child: const Text('초안 저장'),
              ),
              ElevatedButton(
                onPressed: () => _saveCandidate(index, ThinkMemoryStatus.active),
                style: thinkPrimaryButton(),
                child: const Text('승인하고 저장'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _editField(String label, String value, ValueChanged<String> onChanged, {int lines = 1}) {
    return TextFormField(
      initialValue: value,
      minLines: lines,
      maxLines: lines + 4,
      style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.4),
      decoration: thinkInputDecoration(label: label),
      onChanged: onChanged,
    );
  }
}
