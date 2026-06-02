import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mneme_flutter/screens/design_preview/design_preview_hub_screen.dart'
    as learning_preview;
import 'package:mneme_flutter/theme/ygg_semantic_colors.dart';
import 'package:yggdrasill_manager/screens/design_preview/design_preview_hub_screen.dart'
    as manager_preview;

void main() {
  runApp(const YggdrasillDesignPreviewApp());
}

class YggdrasillDesignPreviewApp extends StatefulWidget {
  const YggdrasillDesignPreviewApp({super.key});

  @override
  State<YggdrasillDesignPreviewApp> createState() =>
      _YggdrasillDesignPreviewAppState();
}

class _YggdrasillDesignPreviewAppState
    extends State<YggdrasillDesignPreviewApp> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'design-preview-root');
  bool _isDarkMode = true;
  int _darkSurfaceBaseIndex = 2; // surfaceBase Dark 확정: #000000

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _toggleThemeMode() {
    setState(() => _isDarkMode = !_isDarkMode);
  }

  void _cycleDarkSurfaceBase() {
    if (!_isDarkMode) return;
    setState(() {
      _darkSurfaceBaseIndex =
          (_darkSurfaceBaseIndex + 1) %
          YggSemanticColors.surfaceBaseDarkCandidates.length;
    });
  }

  String get _surfaceBaseBannerLabel {
    if (!_isDarkMode) {
      return 'surfaceBase ${YggSemanticColors.hex(YggSemanticColors.surfaceBaseLight)} · Space';
    }
    final label =
        YggSemanticColors.surfaceBaseDarkCandidateLabels[_darkSurfaceBaseIndex];
    final n = _darkSurfaceBaseIndex + 1;
    final total = YggSemanticColors.surfaceBaseDarkCandidates.length;
    return 'surfaceBase $label ($n/$total) · Enter · Space';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yggdrasill Design Preview',
      debugShowCheckedModeBanner: true,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        return KeyboardListener(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (event) {
            if (event is! KeyDownEvent) return;
            if (event.logicalKey == LogicalKeyboardKey.space) {
              _toggleThemeMode();
            } else if (event.logicalKey == LogicalKeyboardKey.enter) {
              _cycleDarkSurfaceBase();
            }
          },
          child: _ThemeModeBanner(
            label: _surfaceBaseBannerLabel,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: const _PreviewRootScreen(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final surfaceBase = isDark
        ? YggSemanticColors.surfaceBaseDarkCandidates[_darkSurfaceBaseIndex]
        : YggSemanticColors.surfaceBaseLight;
    final semantic = isDark
        ? YggSemanticColors.dark(surfaceBase: surfaceBase)
        : YggSemanticColors.light();

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: surfaceBase,
      extensions: <ThemeExtension<dynamic>>[semantic],
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF33A373),
        brightness: brightness,
        surface: surfaceBase,
      ),
      fontFamily: 'KakaoSmallSans',
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontFamily: 'KakaoBigSans'),
        titleMedium: TextStyle(fontFamily: 'KakaoBigSans'),
        titleSmall: TextStyle(fontFamily: 'KakaoBigSans'),
      ),
    );
  }
}

class _PreviewRootScreen extends StatelessWidget {
  const _PreviewRootScreen();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: context.yggSurfaceBase,
      appBar: AppBar(
        backgroundColor: scheme.surfaceContainerHighest,
        foregroundColor: scheme.onSurface,
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
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '본앱과 다른 Flutter 프로젝트라 Windows build/Debug 산출물이 충돌하지 않습니다.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              'Space: 라이트/다크 전환 · Enter(다크만): surfaceBase 후보 순환',
              style: TextStyle(color: scheme.primary, fontSize: 13),
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
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Card(
      color: isDark ? _panel : scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: isDark ? _border : scheme.outlineVariant),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        title: Text(
          title,
          style: TextStyle(
            color: isDark ? _text : scheme.onSurface,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            subtitle,
            style: TextStyle(color: isDark ? _sub : scheme.onSurfaceVariant),
          ),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: isDark ? _accent : scheme.primary,
        ),
        onTap: onTap,
      ),
    );
  }
}

class _ThemeModeBanner extends StatelessWidget {
  final String label;
  final Widget child;

  const _ThemeModeBanner({
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        child,
        Positioned(
          right: 16,
          bottom: 16,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.inverseSurface.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Text(
                  label,
                  style: TextStyle(
                    color: scheme.onInverseSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
