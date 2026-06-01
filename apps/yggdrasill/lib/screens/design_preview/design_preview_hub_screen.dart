import 'package:flutter/material.dart';

import '../settings/settings_screen.dart';
import '../../widgets/dialog_tokens.dart';
import 'yggdrasill/settings/settings_preview_screen.dart';

/// 완전 분리 Preview 앱에서 표시하는 학습앱 Preview 목록.
class DesignPreviewHubScreen extends StatelessWidget {
  const DesignPreviewHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDlgBg,
      appBar: AppBar(
        backgroundColor: kDlgPanelBg,
        foregroundColor: kDlgText,
        title: const Text('Design Preview Hub (학습앱)'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const YggDialogSectionHeader(
            icon: Icons.phone_android_outlined,
            title: 'yggdrasill',
          ),
          _PreviewTile(
            title: '설정 - 실제 기준선',
            subtitle: '프로덕션 SettingsScreen 그대로 표시 (미세 조정 기준)',
            badge: 'BASELINE',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
          _PreviewTile(
            title: '설정 - 컨셉 목업',
            subtitle: 'mock 데이터 기반 단순화 시안 (실제 반영 전 비교용)',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsPreviewScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          const YggDialogSectionHeader(
            icon: Icons.devices_other_outlined,
            title: 'm5',
          ),
          ListTile(
            title: Text('(예정) M5 바인딩 히스토리', style: TextStyle(color: kDlgTextSub)),
            subtitle: Text(
              'lib/screens/design_preview/m5/',
              style: TextStyle(color: kDlgTextSub, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? badge;
  final VoidCallback onTap;

  const _PreviewTile({
    required this.title,
    required this.subtitle,
    this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: kDlgPanelBg,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Row(
          children: [
            Text(title, style: const TextStyle(color: kDlgText)),
            if (badge != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: kDlgAccent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  badge!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(subtitle, style: const TextStyle(color: kDlgTextSub)),
        trailing: const Icon(Icons.chevron_right, color: kDlgTextSub),
        onTap: onTap,
      ),
    );
  }
}
