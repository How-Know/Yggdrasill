import 'package:flutter/material.dart';

import '../../services/think/think_code_controller.dart';
import '../../services/think/think_code_models.dart';
import 'think_action_cards.dart';
import 'think_code_request_dialog.dart';
import 'think_code_views.dart';
import 'think_style.dart';

/// 모든 코드 요청(조사·수정)을 한곳에서 본다. 평소에는 채팅 카드로 다루고,
/// 대화와 연결되지 않은 요청이나 지난 요청을 찾을 때 연다.
Future<void> showThinkCodeRequests(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.of(ctx).size;
      return Dialog(
        backgroundColor: kThinkBg,
        shape: thinkDialogShape,
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: size.width < 1280 ? size.width - 48 : 1232,
          height: size.height - 48,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
                child: Row(
                  children: [
                    const Text('전체 코드 요청', style: TextStyle(color: kThinkText, fontSize: 18, fontWeight: FontWeight.w800)),
                    const Spacer(),
                    IconButton(
                      tooltip: '닫기',
                      color: kThinkSub,
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Expanded(child: Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 16), child: ThinkCodeRequestsView())),
            ],
          ),
        ),
      );
    },
  );
}

class ThinkCodeRequestsView extends StatefulWidget {
  const ThinkCodeRequestsView({super.key});

  @override
  State<ThinkCodeRequestsView> createState() => _ThinkCodeRequestsViewState();
}

class _ThinkCodeRequestsViewState extends State<ThinkCodeRequestsView> {
  ThinkCodeController get _c => ThinkCodeController.instance;

  Future<void> _create() async {
    final saved = await ThinkCodeRequestDialog.create(context);
    if (saved != null) _c.select(saved.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final selected = _c.selected;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 420, child: _listPanel()),
            const SizedBox(width: 16),
            Expanded(
              child: ThinkPanel(
                child: selected == null
                    ? const Center(
                        child: Text(
                          '왼쪽에서 요청을 고르세요.\n대화에서 Think에게 코드 조사·수정을 부탁하거나, 답변 옆 조사 버튼으로도 만들 수 있습니다.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: kThinkHint, height: 1.6),
                        ),
                      )
                    : ListView(
                        key: PageStorageKey('code-${selected.id}'),
                        padding: const EdgeInsets.all(24),
                        children: [ThinkCodeRequestCard(key: ValueKey(selected.id), request: selected, inChat: false)],
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _listPanel() {
    final items = _c.requests;
    final online = _c.onlineWorker;
    final last = _c.lastWorker;
    return ThinkPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
            child: Row(
              children: [
                Text('오늘 ${_c.submittedToday}/${_c.dailyLimit}건', style: const TextStyle(color: kThinkSub, fontSize: 13)),
                const Spacer(),
                IconButton(
                  tooltip: '새로고침',
                  iconSize: 18,
                  color: kThinkSub,
                  onPressed: _c.loading ? null : () => _c.refresh(),
                  icon: const Icon(Icons.refresh),
                ),
                const SizedBox(width: 4),
                OutlinedButton.icon(
                  onPressed: _create,
                  style: thinkOutlineButton(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('새 조사 요청'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Icon(Icons.circle, size: 8, color: online != null ? kThinkSuccess : kThinkHint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    online != null
                        ? '작업자 켜짐 · ${online.workerId}'
                        : last == null
                            ? '작업자가 아직 연결된 적이 없습니다'
                            : '작업자 꺼짐 · 마지막 신호 ${formatRelative(last.lastSeenAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kThinkSub, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: kThinkBorder, height: 1),
          Expanded(
            child: _c.loading && items.isEmpty
                ? const Center(child: CircularProgressIndicator(color: kThinkAccent))
                : _c.error != null && items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_c.error!, style: const TextStyle(color: kThinkSub, fontSize: 12)),
                      )
                    : items.isEmpty
                        ? const Center(child: Text('아직 보낸 요청이 없습니다.', style: TextStyle(color: kThinkHint)))
                        : ListView.builder(
                            padding: const EdgeInsets.all(8),
                            itemCount: items.length,
                            itemBuilder: (_, i) => _tile(items[i]),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _tile(ThinkCodeRequest r) {
    final selected = _c.selectedId == r.id;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => _c.select(r.id),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ThinkBadge(r.statusLabel, color: thinkCodeStatusColor(r.status)),
                    const SizedBox(width: 4),
                    ThinkBadge(r.mode.label),
                    if (r.outcome != null) ...[
                      const SizedBox(width: 4),
                      ThinkBadge(r.outcome!.label, color: kThinkText),
                    ],
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  r.spec.goal.replaceAll(RegExp(r'\s+'), ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 8),
                Text(
                  [formatRelative(r.submittedAt ?? r.createdAt), if (r.conversationId == null) '대화 연결 없음'].join(' · '),
                  style: const TextStyle(color: kThinkHint, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
