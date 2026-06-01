import 'package:flutter/material.dart';
import 'package:mneme_flutter/screens/design_preview/design_preview_hub_screen.dart'
    as learning_preview;
import 'package:yggdrasill_manager/screens/design_preview/design_preview_hub_screen.dart'
    as manager_preview;

void main() {
  runApp(const YggdrasillDesignPreviewApp());
}

class YggdrasillDesignPreviewApp extends StatelessWidget {
  const YggdrasillDesignPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yggdrasill Design Preview',
      debugShowCheckedModeBanner: true,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B1112),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF33A373),
          brightness: Brightness.dark,
        ),
        fontFamily: 'KakaoSmallSans',
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontFamily: 'KakaoBigSans'),
          titleMedium: TextStyle(fontFamily: 'KakaoBigSans'),
          titleSmall: TextStyle(fontFamily: 'KakaoBigSans'),
        ),
      ),
      home: const _PreviewRootScreen(),
    );
  }
}

class _PreviewRootScreen extends StatelessWidget {
  const _PreviewRootScreen();

  static const Color _bg = Color(0xFF0B1112);
  static const Color _panel = Color(0xFF10171A);
  static const Color _text = Color(0xFFEAF2F2);
  static const Color _sub = Color(0xFF9FB3B3);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _panel,
        foregroundColor: _text,
        title: const Text('Yggdrasill Design Preview'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '완전 분리 Preview 앱',
              style: TextStyle(
                color: _text,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '본앱과 다른 Flutter 프로젝트라 Windows build/Debug 산출물이 충돌하지 않습니다.',
              style: TextStyle(color: _sub, fontSize: 14),
            ),
            const SizedBox(height: 24),
            _PreviewCard(
              title: '학습앱 Preview',
              subtitle: 'apps/yggdrasill/lib/screens/design_preview',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const learning_preview.DesignPreviewHubScreen(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _PreviewCard(
              title: '매니저앱 Preview',
              subtitle: 'apps/yggdrasill_manager/lib/screens/design_preview',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const manager_preview.DesignPreviewHubScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PreviewCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  static const Color _panel = Color(0xFF10171A);
  static const Color _border = Color(0xFF223131);
  static const Color _text = Color(0xFFEAF2F2);
  static const Color _sub = Color(0xFF9FB3B3);
  static const Color _accent = Color(0xFF33A373);

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _border),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        title: Text(
          title,
          style: const TextStyle(
            color: _text,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(subtitle, style: const TextStyle(color: _sub)),
        ),
        trailing: const Icon(Icons.chevron_right, color: _accent),
        onTap: onTap,
      ),
    );
  }
}
