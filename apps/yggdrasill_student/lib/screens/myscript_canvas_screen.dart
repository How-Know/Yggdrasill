import 'package:flutter/material.dart';

import '../services/latex_linear.dart';
import '../widgets/math_latex_view.dart';
import '../widgets/myscript_editor_view.dart';
import '../widgets/pencil_input_pad.dart';

/// MyScript 캔버스 비교 (개발용).
///
/// 위: iink SDK 가 제공하는 네이티브 캔버스(EditorViewController) —
/// 실시간 잉크 렌더링 + 점진적 인식 + convert(조판 수식) 지원.
/// 아래: 자체 구현 캔버스(PencilInputPad) — 배치 인식.
/// 같은 수식을 두 캔버스에 써 보고 필기감·인식 품질을 비교해
/// 최종 채택안을 결정하기 위한 화면.
class MyScriptCanvasScreen extends StatefulWidget {
  const MyScriptCanvasScreen({super.key});

  @override
  State<MyScriptCanvasScreen> createState() => _MyScriptCanvasScreenState();
}

class _MyScriptCanvasScreenState extends State<MyScriptCanvasScreen> {
  final MyScriptEditorController _editorController = MyScriptEditorController();

  String? _iinkLatex;
  String? _iinkLinear;
  String? _iinkError;
  bool _iinkBusy = false;

  String _padResult = '';

  Future<void> _refreshIinkResult() async {
    setState(() => _iinkBusy = true);
    try {
      final latex = await _editorController.exportLatex();
      if (!mounted) return;
      setState(() {
        _iinkLatex = latex;
        _iinkLinear = latex == null ? null : latexToLinear(latex);
        _iinkError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _iinkError = '$e');
    } finally {
      if (mounted) setState(() => _iinkBusy = false);
    }
  }

  Future<void> _convert() async {
    setState(() => _iinkBusy = true);
    try {
      final error = await _editorController.convert();
      if (!mounted) return;
      if (error != null && error.isNotEmpty) {
        setState(() => _iinkError = error);
      }
    } finally {
      if (mounted) setState(() => _iinkBusy = false);
    }
    await _refreshIinkResult();
  }

  Future<void> _clearIink() async {
    await _editorController.clear();
    if (!mounted) return;
    setState(() {
      _iinkLatex = null;
      _iinkLinear = null;
      _iinkError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 필기 중 페이지가 움직이면 안 되므로 스크롤 없는 고정 레이아웃.
    // 위(iink 캔버스)가 남는 높이를 모두 쓰고, 아래(자체 캔버스)는 고정 높이.
    return Scaffold(
      appBar: AppBar(title: const Text('MyScript 캔버스 비교 (개발용)')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _SectionCard(
                  title: 'MyScript 제공 캔버스 (iink 에디터)',
                  subtitle: '실시간 잉크 렌더링 · 쓰는 즉시 인식 · 변환 시 조판 수식으로 정리',
                  expandChild: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: theme.dividerColor),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child:
                              MyScriptEditorView(controller: _editorController),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _iinkBusy ? null : _convert,
                            icon: const Icon(Icons.auto_fix_high, size: 18),
                            label: const Text('변환'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _iinkBusy
                                ? null
                                : () => _editorController.undo(),
                            icon: const Icon(Icons.undo, size: 18),
                            label: const Text('실행 취소'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _iinkBusy ? null : _clearIink,
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('지우기'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _iinkBusy ? null : _refreshIinkResult,
                            icon: const Icon(Icons.text_fields, size: 18),
                            label: const Text('인식 결과'),
                          ),
                        ],
                      ),
                      if (_iinkBusy)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      if (_iinkError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _iinkError!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      if (_iinkLatex != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 76,
                              child: Text('2D 수식',
                                  style: theme.textTheme.labelMedium),
                            ),
                            Expanded(
                              child: MathLatexView(
                                  latex: _iinkLatex!, fontSize: 22),
                            ),
                          ],
                        ),
                        _ResultRow(label: 'LaTeX', value: _iinkLatex!),
                        if (_iinkLinear != null)
                          _ResultRow(label: '답 표기', value: _iinkLinear!),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: '자체 구현 캔버스 (현재 문제풀이 화면)',
                subtitle: '2초 멈추면 자동 인식 · MyScript 배치 인식 → ML Kit 폴백',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PencilInputPad(
                      height: 200,
                      onRecognized: (text, {sourceLatex}) =>
                          setState(() => _padResult = text),
                    ),
                    if (_padResult.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _ResultRow(label: '인식 결과', value: _padResult),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
    this.expandChild = false,
  });

  final String title;
  final String subtitle;
  final Widget child;

  /// true 면 child 를 Expanded 로 감싼다. child 내부에 Expanded 가 있는
  /// 경우 Column 이 무제한 높이를 주면 릴리즈에서 크래시가 나므로,
  /// 세로 공간을 채우는 카드는 반드시 이 옵션을 켜야 한다.
  final bool expandChild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: expandChild ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(subtitle, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (expandChild) Expanded(child: child) else child,
          ],
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: theme.textTheme.labelMedium),
          ),
          Expanded(
            child: SelectableText(
              value,
              maxLines: 2,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontFamily: 'Menlo', height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
