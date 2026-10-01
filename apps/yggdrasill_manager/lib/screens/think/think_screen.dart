import 'package:flutter/material.dart';

import '../../services/think/think_code_controller.dart';
import '../../services/think/think_controller.dart';
import 'think_chat_tab.dart';
import 'think_memory_tab.dart';
import 'think_style.dart';
import 'think_usage_tab.dart';

class ThinkScreen extends StatefulWidget {
  const ThinkScreen({super.key});

  @override
  State<ThinkScreen> createState() => _ThinkScreenState();
}

class _ThinkScreenState extends State<ThinkScreen> {
  ThinkController get _c => ThinkController.instance;

  @override
  void initState() {
    super.initState();
    _c.ensureStarted();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ThinkCodeController.instance.setVisible(_c.tab == ThinkController.tabChat);
    });
  }

  @override
  void dispose() {
    ThinkCodeController.instance.setVisible(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        return Container(
          color: kThinkBg,
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Think', style: TextStyle(color: kThinkText, fontSize: 24, fontWeight: FontWeight.w900)),
                        SizedBox(height: 8),
                        Text(
                          '교육철학과 결정을 기억하는 AI와 생각을 정리합니다. 기억과 실행은 직접 확인한 것만 남습니다.',
                          style: TextStyle(color: kThinkSub, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  _statusBadge(),
                  const SizedBox(width: 16),
                  ThinkPillTabs(
                    labels: const ['대화', '기억', '사용량'],
                    icons: const [
                      Icons.forum_outlined,
                      Icons.bookmarks_outlined,
                      Icons.insights_outlined,
                    ],
                    selected: _c.tab,
                    onSelected: _c.setTab,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: _c.forbidden
                    ? _forbidden()
                    : IndexedStack(
                        index: _c.tab,
                        sizing: StackFit.expand,
                        children: const [ThinkChatTab(), ThinkMemoryTab(), ThinkUsageTab()],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statusBadge() {
    final status = _c.status;
    final error = _c.statusError;
    final Widget badge;
    final String tip;
    if (_c.statusLoading && status == null) {
      badge = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: kThinkSub)),
          SizedBox(width: 8),
          Text('연결 확인 중', style: TextStyle(color: kThinkSub, fontSize: 12)),
        ],
      );
      tip = 'ai_think 함수 상태를 확인하고 있습니다.';
    } else if (error != null) {
      badge = ThinkBadge(_c.forbidden ? '권한 없음' : '상태 확인 실패', color: kThinkError);
      tip = error.message;
    } else if (status == null) {
      badge = const ThinkBadge('상태 모름');
      tip = '눌러서 다시 확인';
    } else if (!status.configured) {
      badge = const ThinkBadge('OpenAI 키 없음', color: kThinkError);
      tip = 'Supabase Edge Function 비밀값 OPENAI_API_KEY가 없습니다.\nsupabase secrets set OPENAI_API_KEY=... 로 설정하세요.';
    } else {
      final model = status.models['primary'] ?? '';
      badge = ThinkBadge(
        status.provider == 'fake' ? '가짜 AI (테스트)' : '연결됨 · $model',
        color: status.budgetExceeded ? kThinkError : kThinkAccent,
      );
      tip = [
        '기본 ${status.models['primary'] ?? '-'} · 깊게 ${status.models['deep'] ?? '-'} · 빠른 작업 ${status.models['fast'] ?? '-'}',
        if (status.budgetLimitUsd != null)
          '이번 달 ${formatUsd(status.spentUsd)} / 한도 ${formatUsd(status.budgetLimitUsd, digits: 2)}${status.budgetExceeded ? ' (초과)' : ''}',
        '눌러서 다시 확인',
      ].join('\n');
    }
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: _c.statusLoading ? null : _c.refreshStatus,
        borderRadius: BorderRadius.circular(8),
        child: Padding(padding: const EdgeInsets.all(4), child: badge),
      ),
    );
  }

  Widget _forbidden() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ThinkPanel(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.lock_outline, color: kThinkError),
                  SizedBox(width: 12),
                  Text('슈퍼관리자 전용', style: TextStyle(color: kThinkText, fontSize: 20, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Think는 플랫폼 운영자만 씁니다. app_users.platform_role이 superadmin인 계정으로 로그인하세요.',
                style: TextStyle(color: kThinkSub, fontSize: 14, height: 1.6),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _c.refreshStatus,
                style: thinkPrimaryButton(),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('다시 확인'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
