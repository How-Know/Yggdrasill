import 'package:flutter/material.dart';

import '../../widgets/dialog_tokens.dart';
import 'yggdrasill/settings/settings_preview_screen.dart';

/// kDebugMode 전용 Preview 목록.
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
            title: '설정',
            subtitle: '학원 / 선생님 / 일반 탭 목업',
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
  final VoidCallback onTap;

  const _PreviewTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: kDlgPanelBg,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(title, style: const TextStyle(color: kDlgText)),
        subtitle: Text(subtitle, style: const TextStyle(color: kDlgTextSub)),
        trailing: const Icon(Icons.chevron_right, color: kDlgTextSub),
        onTap: onTap,
      ),
    );
  }
}
