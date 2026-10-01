import 'package:flutter/material.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_style.dart';

/// 대화를 결정 초안으로 정리한다. AI는 초안만 만들고, 저장 여부와 상태는 사람이 정한다.
class ThinkDecisionDialog extends StatefulWidget {
  const ThinkDecisionDialog({super.key, required this.conversationId});

  final String conversationId;

  static Future<ThinkMemory?> show(BuildContext context, {required String conversationId}) {
    return showDialog<ThinkMemory>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ThinkDecisionDialog(conversationId: conversationId),
    );
  }

  @override
  State<ThinkDecisionDialog> createState() => _ThinkDecisionDialogState();
}

class _ThinkDecisionDialogState extends State<ThinkDecisionDialog> {
  final _title = TextEditingController();
  final _decision = TextEditingController();
  final _context = TextEditingController();
  final _reason = TextEditingController();
  final _alternatives = TextEditingController();
  final _tags = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  ThinkDecisionDraft? _draft;
  String? _replacesId;

  ThinkController get _c => ThinkController.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_title, _decision, _context, _reason, _alternatives, _tags]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await ThinkApi.instance.decisionDraft(widget.conversationId);
      if (!mounted) return;
      _title.text = d.title;
      _decision.text = d.decision;
      _context.text = d.context;
      _reason.text = d.reason;
      _alternatives.text = d.alternatives.join('\n');
      _tags.text = d.tags.join(', ');
      setState(() {
        _draft = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ThinkApiException ? e.message : '초안을 만들지 못했습니다: $e';
        _loading = false;
      });
    }
  }

  Future<void> _save(ThinkMemoryStatus status) async {
    if (_title.text.trim().isEmpty || _decision.text.trim().isEmpty) {
      showThinkSnack(context, '제목과 결정 내용을 채워 주세요.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final draft = ThinkMemoryDraft(
        kind: ThinkMemoryKind.decision,
        status: status,
        title: _title.text,
        content: _decision.text,
        decisionContext: _context.text,
        decisionReason: _reason.text,
        alternatives: _alternatives.text.split('\n'),
        tags: _tags.text.split(RegExp(r'[,，]')),
        sourceConversationId: widget.conversationId,
        supersedesId: _replacesId,
      );
      final saved = await _c.saveMemory(draft);
      if (!mounted) return;
      Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showThinkSnack(context, '저장하지 못했습니다: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      title: const Row(
        children: [
          Icon(Icons.fact_check_outlined, color: kThinkAccent, size: 24),
          SizedBox(width: 12),
          Text('결정으로 정리', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800, fontSize: 20)),
        ],
      ),
      content: SizedBox(width: 760, height: 620, child: _body()),
      actions: _loading || _error != null
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('닫기', style: TextStyle(color: kThinkSub)),
              ),
              if (_error != null)
                ElevatedButton(onPressed: _load, style: thinkPrimaryButton(), child: const Text('다시 시도')),
            ]
          : [
              TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: const Text('폐기', style: TextStyle(color: kThinkSub)),
              ),
              OutlinedButton(
                onPressed: _saving ? null : () => _save(ThinkMemoryStatus.draft),
                style: thinkOutlineButton(),
                child: const Text('초안으로 저장'),
              ),
              ElevatedButton.icon(
                onPressed: _saving ? null : () => _save(ThinkMemoryStatus.active),
                style: thinkPrimaryButton(),
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.check, size: 18),
                label: const Text('승인하고 저장'),
              ),
            ],
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: kThinkAccent),
            SizedBox(height: 16),
            Text('대화를 읽고 결정 초안을 만드는 중…', style: TextStyle(color: kThinkSub)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(child: ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline));
    }
    final draft = _draft!;
    final activeDecisions = _c.memories
        .where((m) => m.kind == ThinkMemoryKind.decision && m.status == ThinkMemoryStatus.active)
        .toList();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'AI가 만든 초안입니다. 고친 뒤 저장하세요. 확정하면 다음 대화부터 AI가 이 결정을 기억합니다.',
            style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.5),
          ),
          if (draft.conflicts.isNotEmpty) ...[
            const SizedBox(height: 12),
            ThinkNotice(
              text: '기존 결정·원칙과 부딪칠 수 있는 점\n${draft.conflicts.map((e) => '• $e').join('\n')}',
              color: kThinkError,
              icon: Icons.warning_amber_rounded,
            ),
          ],
          if (draft.openQuestions.isNotEmpty) ...[
            const SizedBox(height: 12),
            ThinkNotice(
              text: '아직 정하지 않은 것\n${draft.openQuestions.map((e) => '• $e').join('\n')}',
              icon: Icons.help_outline,
            ),
          ],
          const SizedBox(height: 16),
          _field(_title, '제목'),
          const SizedBox(height: 12),
          _field(_decision, '결정 내용', lines: 4),
          const SizedBox(height: 12),
          _field(_context, '배경 (왜 이 문제를 다뤘나)', lines: 3),
          const SizedBox(height: 12),
          _field(_reason, '이유', lines: 3),
          const SizedBox(height: 12),
          _field(_alternatives, '검토한 대안 (한 줄에 하나)', lines: 3),
          const SizedBox(height: 12),
          _field(_tags, '태그 (쉼표로 구분)'),
          if (activeDecisions.isNotEmpty) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _replacesId,
              isExpanded: true,
              dropdownColor: kThinkPanel,
              style: const TextStyle(color: kThinkText, fontSize: 14),
              decoration: thinkInputDecoration(label: '대체할 기존 결정 (있으면 선택)'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('없음')),
                for (final m in activeDecisions)
                  DropdownMenuItem<String?>(
                    value: m.id,
                    child: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _replacesId = v),
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {int lines = 1}) {
    return TextField(
      controller: c,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 6,
      style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
      decoration: thinkInputDecoration(label: label),
    );
  }
}
