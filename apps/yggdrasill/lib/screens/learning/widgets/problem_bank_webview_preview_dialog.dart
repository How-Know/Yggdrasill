import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../../services/learning_problem_bank_service.dart';

const Color _bg = Color(0xFF10171A);
const Color _border = Color(0xFF223131);
const Color _text = Color(0xFFEAF2F2);
const Color _sub = Color(0xFF9FB3B3);
const Color _chipBg = Color(0xFF151E24);

class ProblemBankWebViewPreviewDialog extends StatefulWidget {
  const ProblemBankWebViewPreviewDialog({
    super.key,
    required this.academyId,
    required this.questionIds,
    required this.service,
    this.titleText = '문항 미리보기',
    this.profile = 'naesin',
    this.paper = 'B4',
    this.maxQuestionsPerPage = 4,
    this.initialRenderConfig,
    this.initialBaseLayout,
  });

  final String academyId;
  final List<String> questionIds;
  final LearningProblemBankService service;
  final String titleText;
  final String profile;
  final String paper;
  final int maxQuestionsPerPage;
  final Map<String, dynamic>? initialRenderConfig;
  final Map<String, dynamic>? initialBaseLayout;

  static Future<void> open(
    BuildContext context, {
    required String academyId,
    required List<String> questionIds,
    required LearningProblemBankService service,
    String titleText = '문항 미리보기',
    String profile = 'naesin',
    String paper = 'B4',
    int maxQuestionsPerPage = 4,
    Map<String, dynamic>? renderConfig,
    Map<String, dynamic>? baseLayout,
  }) async {
    final size = MediaQuery.sizeOf(context);
    final maxWidth = (size.width - 40).clamp(920.0, 1640.0).toDouble();
    final maxHeight = (size.height * 0.88).clamp(640.0, 1280.0).toDouble();
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: _bg,
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            minWidth: 780,
            minHeight: 620,
          ),
          child: ProblemBankWebViewPreviewDialog(
            academyId: academyId,
            questionIds: questionIds,
            service: service,
            titleText: titleText,
            profile: profile,
            paper: paper,
            maxQuestionsPerPage: maxQuestionsPerPage,
            initialRenderConfig: renderConfig,
            initialBaseLayout: baseLayout,
          ),
        ),
      ),
    );
  }

  @override
  State<ProblemBankWebViewPreviewDialog> createState() =>
      _ProblemBankWebViewPreviewDialogState();
}

class _ProblemBankWebViewPreviewDialogState
    extends State<ProblemBankWebViewPreviewDialog> {
  final WebviewController _webview = WebviewController();
  bool _webviewReady = false;
  bool _loading = true;
  String? _error;
  String? _htmlFilePath;

  double _stemSizePt = 11.0;
  double _lineHeightPt = 15.0;
  double _questionGapPt = 30.0;
  double _choiceGapPt = 2.0;

  @override
  void initState() {
    super.initState();
    final bl = widget.initialBaseLayout ?? {};
    _stemSizePt = (bl['stemSize'] as num?)?.toDouble() ?? 11.0;
    _lineHeightPt = (bl['lineHeight'] as num?)?.toDouble() ?? 15.0;
    _questionGapPt = (bl['questionGap'] as num?)?.toDouble() ?? 30.0;
    _choiceGapPt = (bl['choiceSpacing'] as num?)?.toDouble() ?? 2.0;
    _initWebView();
  }

  Future<void> _initWebView() async {
    try {
      await _webview.initialize();
      if (!mounted) return;
      setState(() => _webviewReady = true);
      await _loadHtml();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '미리보기 초기화 실패: $e';
        _loading = false;
      });
    }
  }

  Future<void> _loadHtml() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final renderConfig = <String, dynamic>{
        ...?widget.initialRenderConfig,
        'includeAnswerSheet':
            widget.initialRenderConfig?['includeAnswerSheet'] ?? true,
      };
      final baseLayout = <String, dynamic>{
        'stemSize': _stemSizePt,
        'lineHeight': _lineHeightPt,
        'questionGap': _questionGapPt,
        'choiceSpacing': _choiceGapPt,
      };

      final html = await widget.service.fetchDocumentPreviewHtml(
        academyId: widget.academyId,
        questionIds: widget.questionIds,
        renderConfig: renderConfig,
        profile: widget.profile,
        paper: widget.paper,
        baseLayout: baseLayout,
        maxQuestionsPerPage: widget.maxQuestionsPerPage,
      );

      if (!mounted) return;
      if (html == null || html.isEmpty) {
        setState(() {
          _error = 'HTML을 가져올 수 없습니다.';
          _loading = false;
        });
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/pb_preview_${DateTime.now().millisecondsSinceEpoch}.html');
      await file.writeAsString(html, encoding: utf8);
      _htmlFilePath = file.path;

      if (_webviewReady) {
        await _webview.loadUrl(Uri.file(file.path).toString());
      }

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '미리보기 로드 실패: $e';
        _loading = false;
      });
    }
  }

  Future<void> _updateCssVariable(String name, double value) async {
    if (!_webviewReady) return;
    try {
      await _webview.executeScript(
        "document.documentElement.style.setProperty('$name', '$value');",
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _webview.dispose();
    if (_htmlFilePath != null) {
      try { File(_htmlFilePath!).deleteSync(); } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        children: [
          _buildTitleBar(),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildPreviewArea()),
                const SizedBox(width: 12),
                SizedBox(width: 220, child: _buildLayoutPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleBar() {
    return Row(
      children: [
        Expanded(
          child: Text(
            widget.titleText,
            style: const TextStyle(
              color: _text,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: '닫기',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, color: _sub),
        ),
      ],
    );
  }

  Widget _buildPreviewArea() {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: _sub, fontWeight: FontWeight.w700)),
      );
    }
    if (_loading || !_webviewReady) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Webview(_webview),
    );
  }

  Widget _buildLayoutPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _chipBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '레이아웃 조정',
              style: TextStyle(
                color: _text,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            _buildSlider(
              label: '글자 크기',
              value: _stemSizePt,
              min: 8,
              max: 16,
              unit: 'pt',
              onChanged: (v) {
                setState(() => _stemSizePt = v);
                _updateCssVariable('--stem-size-pt', v);
              },
            ),
            _buildSlider(
              label: '줄간격',
              value: _lineHeightPt,
              min: 10,
              max: 24,
              unit: 'pt',
              onChanged: (v) {
                setState(() => _lineHeightPt = v);
                _updateCssVariable('--line-height-pt', v);
              },
            ),
            _buildSlider(
              label: '문항 간격',
              value: _questionGapPt,
              min: 5,
              max: 60,
              unit: 'pt',
              onChanged: (v) {
                setState(() => _questionGapPt = v);
                _updateCssVariable('--question-gap-pt', v);
              },
            ),
            _buildSlider(
              label: '선지 간격',
              value: _choiceGapPt,
              min: 0,
              max: 10,
              unit: 'pt',
              onChanged: (v) {
                setState(() => _choiceGapPt = v);
                _updateCssVariable('--choice-gap-pt', v);
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF173C36),
                  foregroundColor: const Color(0xFFC7F2D8),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _loading ? null : _loadHtml,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text(
                  '서버 재렌더링',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String unit,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: const TextStyle(color: _sub, fontSize: 12, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(
                '${value.toStringAsFixed(1)} $unit',
                style: const TextStyle(color: _text, fontSize: 12, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: const Color(0xFF2F786B),
              inactiveTrackColor: _border,
              thumbColor: const Color(0xFF4ECFB5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
