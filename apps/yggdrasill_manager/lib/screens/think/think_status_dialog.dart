import 'package:flutter/material.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_code_controller.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_split_views.dart';
import 'think_style.dart';

/// ai_think·Supabase·코드 작업자·종합 문서 probe를 한곳에서 본다. 실패는 숨기지 않고 URL·키는 표시하지 않는다.
Future<void> showThinkStatusDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _ThinkStatusDialog(),
  );
}

class _ThinkStatusDialog extends StatefulWidget {
  const _ThinkStatusDialog();

  @override
  State<_ThinkStatusDialog> createState() => _ThinkStatusDialogState();
}

class _ThinkStatusDialogState extends State<_ThinkStatusDialog> {
  ThinkController get _c => ThinkController.instance;
  ThinkCodeController get _code => ThinkCodeController.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.refreshConnectionDetails());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_c, _code]),
      builder: (context, _) {
        final status = _c.status;
        final err = _c.statusError;
        final probe = _c.documentProbe;
        return AlertDialog(
          backgroundColor: kThinkBg,
          shape: thinkDialogShape,
          title: const Row(
            children: [
              Icon(Icons.link, color: kThinkAccent, size: 22),
              SizedBox(width: 12),
              Text('Think 연결 상태', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800, fontSize: 18)),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _section('Supabase 프로젝트', [
                    _line('식별', _c.supabaseProjectRef ?? '(URL을 해석하지 못함)'),
                    _line('함수', ThinkApi.functionName),
                  ]),
                  _section('ai_think (Edge)', [
                    if (_c.statusLoading && status == null)
                      const Text('확인 중…', style: TextStyle(color: kThinkSub, fontSize: 13))
                    else if (err != null)
                      ThinkNotice(text: err.message, color: kThinkError, icon: Icons.error_outline)
                    else if (status == null)
                      const Text('상태를 아직 받지 못했습니다.', style: TextStyle(color: kThinkHint, fontSize: 13))
                    else ...[
                      _line('구성', status.configured ? 'OpenAI 키 있음' : 'OpenAI 키 없음 (503)'),
                      _line('provider', status.provider.isEmpty ? '-' : status.provider),
                      _line('prompt_version', status.promptVersion.isEmpty ? '-' : status.promptVersion),
                      _line('primary', status.models['primary'] ?? '-'),
                      _line('deep', status.models['deep'] ?? '-'),
                      _line('fast', status.models['fast'] ?? '-'),
                      _line('웹 검색', status.webSearchEnabled ? '허용' : '꺼짐'),
                      if (status.budgetLimitUsd != null)
                        _line(
                          '이번 달 비용',
                          '${formatUsd(status.spentUsd)} / ${formatUsd(status.budgetLimitUsd, digits: 2)} (${status.budgetMode})'
                          '${status.budgetExceeded ? ' · 초과' : ''}',
                        ),
                    ],
                  ]),
                  if (status != null && err == null)
                    _section('기능 상태 (서버가 요청마다 확인)', [
                      ThinkFeatureStatusView(
                        feature: status.conversationSplit,
                        dbError: status.featuresDbError,
                        detailed: true,
                      ),
                      const SizedBox(height: 12),
                      ThinkFeatureStatusView(
                        feature: status.thinkRoles,
                        label: '역할·자료 범위',
                        reason: thinkRolesFeatureReason,
                        detailed: true,
                      ),
                    ]),
                  _section('코드 작업자 (code bridge)', [thinkCodeWorkerLine(_code)]),
                  _section('종합 문서 (읽기 probe)', [
                    const Text(
                      '데이터를 만들거나 고치지 않고, 컬럼·RPC 응답만 확인합니다. 조회만으로 생성·수정 가능 여부는 알 수 없습니다.',
                      style: TextStyle(color: kThinkSub, fontSize: 12, height: 1.5),
                    ),
                    const SizedBox(height: 8),
                    if (_c.documentProbeLoading)
                      const Text('probe 실행 중…', style: TextStyle(color: kThinkSub, fontSize: 13))
                    else if (_c.documentProbeError != null)
                      ThinkNotice(
                        text: 'probe를 끝내지 못했습니다: ${_c.documentProbeError}',
                        color: kThinkError,
                        icon: Icons.error_outline,
                      )
                    else if (probe == null)
                      const Text('아직 probe를 실행하지 않았습니다.', style: TextStyle(color: kThinkHint, fontSize: 13))
                    else ...[
                      _probeLine('ai_tree_nodes.body 컬럼', probe.bodyColumn),
                      _probeLine('ai_tree_get_document RPC', probe.getDocumentRpc),
                      _probeLine('ai_tree_create_document (빈 출처)', probe.createRpc),
                      for (final e in probe.detail.entries)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${e.key}: ${e.value.replaceAll(RegExp(r'https?://\S+'), '[URL]')}',
                            style: const TextStyle(color: kThinkHint, fontSize: 11, height: 1.4),
                          ),
                        ),
                    ],
                  ]),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기', style: TextStyle(color: kThinkSub)),
            ),
            ElevatedButton.icon(
              onPressed: _c.statusLoading || _c.documentProbeLoading ? null : () => _c.refreshConnectionDetails(),
              style: thinkPrimaryButton(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('다시 확인'),
            ),
          ],
        );
      },
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 120, child: Text(label, style: const TextStyle(color: kThinkSub, fontSize: 12))),
            Expanded(child: SelectableText(value, style: const TextStyle(color: kThinkText, fontSize: 12, height: 1.4))),
          ],
        ),
      );

  Widget _probeLine(String label, ThinkProbeOutcome o) => _line(label, o.label);
}

Widget thinkCodeWorkerLine(ThinkCodeController c) {
  final online = c.onlineWorker;
  final last = c.lastWorker;
  final String text;
  if (online != null) {
    text = '작업자 켜짐 · ${online.workerId}${online.currentRequestId != null ? ' · 작업 중' : ''}';
  } else {
    text = last == null ? '작업자가 아직 연결된 적이 없습니다' : '작업자 꺼짐 · 마지막 신호 ${formatRelative(last.lastSeenAt)}';
  }
  return Row(
    children: [
      Icon(Icons.circle, size: 8, color: online != null ? kThinkSuccess : kThinkHint),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(color: kThinkSub, fontSize: 12))),
      Text('오늘 ${c.submittedToday}/${c.dailyLimit}건', style: const TextStyle(color: kThinkHint, fontSize: 12)),
    ],
  );
}
