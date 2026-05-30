import 'package:flutter/material.dart';

import 'yggdrasill_manager/settings/management_settings_preview_screen.dart';

/// kDebugMode 전용 Preview 목록 (매니저앱).
class DesignPreviewHubScreen extends StatelessWidget {
  const DesignPreviewHubScreen({super.key});

  static const Color _bg = Color(0xFF1F1F1F);
  static const Color _card = Color(0xFF18181A);
  static const Color _border = Color(0xFF2A2A2A);
  static const Color _text = Colors.white;
  static const Color _sub = Color(0xFFB3B3B3);
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        title: const Text('Design Preview Hub (매니저)'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'yggdrasill_manager',
            style: TextStyle(
              color: _text,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            color: _card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: _border),
            ),
            child: ListTile(
              title: const Text('설정', style: TextStyle(color: _text)),
              subtitle: const Text(
                '성향조사 웹 / OpenAI 키 / 소유자 (목업)',
                style: TextStyle(color: _sub),
              ),
              trailing: const Icon(Icons.chevron_right, color: _sub),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ManagementSettingsPreviewScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '학습앱·M5 Preview는 apps/yggdrasill 쪽 design_preview 를 사용하세요.',
            style: TextStyle(color: _sub, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
