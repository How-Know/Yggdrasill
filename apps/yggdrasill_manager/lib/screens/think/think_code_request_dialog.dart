import 'package:flutter/material.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_code_controller.dart';
import '../../services/think/think_code_models.dart';
import '../../services/think/think_models.dart';
import 'think_style.dart';

const int _kBackgroundMax = 6000;

String _clip(String text, int max) {
  final t = text.trim();
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

/// Cursor에 보낼 코드 조사 요청을 쓴다. 조사와 수정 제안만 받고 코드는 고치지 않는다.
class ThinkCodeRequestDialog extends StatefulWidget {
  const ThinkCodeRequestDialog._({
    this.draft,
    this.title = '',
    this.goal = '',
    this.background = '',
    this.conversationId,
    this.sourceMessageIds = const [],
  });

  final ThinkCodeRequest? draft;
  final String title;
  final String goal;
  final String background;
  final String? conversationId;
  final List<String> sourceMessageIds;

  static Future<ThinkCodeRequest?> create(BuildContext context) =>
      showDialog<ThinkCodeRequest>(context: context, builder: (_) => const ThinkCodeRequestDialog._());

  static Future<ThinkCodeRequest?> edit(BuildContext context, ThinkCodeRequest draft) =>
      showDialog<ThinkCodeRequest>(context: context, builder: (_) => ThinkCodeRequestDialog._(draft: draft));

  /// 대화의 한 문답에서 시작한다. 질문은 목표로, Think 답변은 배경으로 채운다.
  static Future<ThinkCodeRequest?> fromTurn(
    BuildContext context, {
    required String? conversationId,
    required List<ThinkMessage> messages,
    required int index,
  }) {
    final turn = [for (final i in thinkTurnIndices(messages, index)) messages[i]];
    final question = turn.where((m) => m.isUser).map((m) => m.content.trim()).join('\n\n');
    final answer = turn.where((m) => !m.isUser).map((m) => m.content.trim()).join('\n\n');
    final firstLine = question.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    return showDialog<ThinkCodeRequest>(
      context: context,
      builder: (_) => ThinkCodeRequestDialog._(
        title: _clip(firstLine, 60),
        goal: _clip(question, 2000),
        background: answer.isEmpty ? '' : 'Think 답변:\n${_clip(answer, _kBackgroundMax)}',
        conversationId: conversationId,
        sourceMessageIds: [
          for (final m in turn)
            if ((m.id ?? '').isNotEmpty) m.id!,
        ],
      ),
    );
  }

  @override
  State<ThinkCodeRequestDialog> createState() => _ThinkCodeRequestDialogState();
}

class _ThinkCodeRequestDialogState extends State<ThinkCodeRequestDialog> {
  ThinkCodeController get _c => ThinkCodeController.instance;

  late final TextEditingController _title;
  late final TextEditingController _goal;
  late final TextEditingController _background;
  late final TextEditingController _questions;
  late final TextEditingController _paths;
  late final TextEditingController _constraints;
  late final TextEditingController _doNot;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    final s = d?.spec;
    _title = TextEditingController(text: d?.title ?? widget.title);
    _goal = TextEditingController(text: s?.goal ?? widget.goal);
    _background = TextEditingController(text: s?.background ?? widget.background);
    _questions = TextEditingController(text: (s?.questions ?? const []).join('\n'));
    _paths = TextEditingController(text: (s?.focusPaths ?? const []).join('\n'));
    _constraints = TextEditingController(text: (s?.constraints ?? const []).join('\n'));
    _doNot = TextEditingController(text: (s?.doNot ?? const []).join('\n'));
    _c.addListener(_onChange);
    if (_c.requests.isEmpty && !_c.loading) _c.refresh(quiet: true);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    for (final t in [_title, _goal, _background, _questions, _paths, _constraints, _doNot]) {
      t.dispose();
    }
    super.dispose();
  }

  ThinkCodeSpec _spec() => ThinkCodeSpec(
        goal: _goal.text,
        background: _background.text,
        questions: ThinkCodeSpec.lines(_questions.text),
        focusPaths: ThinkCodeSpec.lines(_paths.text),
        constraints: ThinkCodeSpec.lines(_constraints.text),
        doNot: ThinkCodeSpec.lines(_doNot.text),
      );

  Future<void> _save({required bool submit}) async {
    final title = _title.text.trim();
    if (title.isEmpty || title.length > 200) {
      setState(() => _error = '제목을 1~200자로 입력하세요.');
      return;
    }
    if (_goal.text.trim().isEmpty) {
      setState(() => _error = '목표를 입력하세요. 무엇을 알고 싶은지 한두 문장이면 됩니다.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    ThinkCodeRequest? saved;
    try {
      saved = await _c.save(
        id: widget.draft?.id,
        title: title,
        spec: _spec(),
        conversationId: widget.draft == null ? widget.conversationId : null,
        sourceMessageIds: widget.draft == null ? widget.sourceMessageIds : const [],
        submit: submit,
      );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      final message = ThinkApi.codeErrorMessage(e);
      final draftKept = submit && _c.selected != null && _c.selected!.status == ThinkCodeStatus.draft;
      if (draftKept) {
        Navigator.pop(context, _c.selected);
        showThinkSnack(context, '초안은 저장했지만 보내지 못했습니다. $message', error: true);
        return;
      }
      setState(() {
        _saving = false;
        _error = message;
      });
    }
  }

  Widget _field(TextEditingController c, String label, {String? hint, int minLines = 1, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        minLines: minLines,
        maxLines: maxLines,
        style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
        decoration: thinkInputDecoration(label: label, hint: hint),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final worker = _c.onlineWorker;
    final used = _c.submittedToday;
    final limit = _c.dailyLimit;
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(
        widget.draft == null ? '코드 조사 요청' : '코드 조사 초안 편집',
        style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ThinkNotice(
                text: 'Cursor가 저장소를 읽기만 하고 조사 결과와 수정 제안을 돌려줍니다. 코드는 고치지 않습니다.',
                icon: Icons.manage_search,
              ),
              const SizedBox(height: 16),
              _field(_title, '제목'),
              _field(_goal, '목표', hint: '무엇을 알고 싶은지. 예) 출석 카드에 지각 표시를 넣으려면 어디를 바꿔야 하는지', minLines: 2, maxLines: 6),
              _field(_questions, '확인할 질문 (한 줄에 하나, 선택)', minLines: 2, maxLines: 6),
              _field(_paths, '우선 볼 폴더 (한 줄에 하나, 비우면 저장소 전체)', hint: '예) apps/yggdrasill/lib/screens', minLines: 1, maxLines: 4),
              _field(_constraints, '지켜야 할 제약 (한 줄에 하나, 선택)', minLines: 1, maxLines: 4),
              _field(_doNot, '제안하지 말 것 (한 줄에 하나, 선택)', minLines: 1, maxLines: 4),
              _field(_background, '배경 (선택)', hint: 'Cursor가 알아야 할 대화 맥락', minLines: 2, maxLines: 8),
              Row(
                children: [
                  Icon(Icons.circle, size: 8, color: worker != null ? kThinkSuccess : kThinkHint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      worker != null
                          ? '작업자 켜짐 (${worker.workerId}). 보내면 곧 시작합니다.'
                          : '작업자가 꺼져 있습니다. 보내 두면 이 PC에서 작업자를 켰을 때 시작합니다.',
                      style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.4),
                    ),
                  ),
                  Text('오늘 $used/$limit건', style: const TextStyle(color: kThinkHint, fontSize: 12)),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        OutlinedButton(
          onPressed: _saving ? null : () => _save(submit: false),
          style: thinkOutlineButton(),
          child: const Text('초안 저장'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : () => _save(submit: true),
          style: thinkPrimaryButton(),
          child: Text(_saving ? '처리 중…' : '보내기'),
        ),
      ],
    );
  }
}
