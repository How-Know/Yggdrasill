import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_windows/webview_windows.dart';

class MathLiveEditorDialog extends StatefulWidget {
  const MathLiveEditorDialog({
    super.key,
    required this.initialLatex,
    required this.block,
  });

  final String initialLatex;
  final bool block;

  static Future<String?> show({
    required BuildContext context,
    required String initialLatex,
    required bool block,
  }) async {
    // webview_windows 기반 구현이므로 비Windows는 텍스트 폴백
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return _showPlainFallback(
        context: context,
        initialLatex: initialLatex,
      );
    }
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => MathLiveEditorDialog(
        initialLatex: initialLatex,
        block: block,
      ),
    );
  }

  static Future<String?> _showPlainFallback({
    required BuildContext context,
    required String initialLatex,
  }) async {
    final ctrl = TextEditingController(text: initialLatex);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0B1112),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF223131)),
          ),
          title: const Text(
            '수식 입력(텍스트 모드)',
            style: TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900),
          ),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              style: const TextStyle(color: Color(0xFFEAF2F2)),
              decoration: InputDecoration(
                hintText: r'{x}^{2}, \frac{a}{b}, \sqrt{x}',
                hintStyle: const TextStyle(color: Color(0xFF9FB3B3)),
                filled: true,
                fillColor: const Color(0xFF15171C),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF223131)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF223131)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF33A373), width: 1.2),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소', style: TextStyle(color: Color(0xFF9FB3B3))),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF33A373)),
              child: const Text('삽입', style: TextStyle(color: Color(0xFFEAF2F2))),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    return result;
  }

  @override
  State<MathLiveEditorDialog> createState() => _MathLiveEditorDialogState();
}

class _MathLiveEditorDialogState extends State<MathLiveEditorDialog> {
  static const Color _bg = Color(0xFF0B1112);
  static const Color _panel = Color(0xFF10171A);
  static const Color _field = Color(0xFF15171C);
  static const Color _border = Color(0xFF223131);
  static const Color _text = Color(0xFFEAF2F2);
  static const Color _textSub = Color(0xFF9FB3B3);
  static const Color _accent = Color(0xFF33A373);

  final WebviewController _controller = WebviewController();
  StreamSubscription? _webMessageSub;
  final TextEditingController _fallbackCtrl = TextEditingController();

  bool _loading = true;
  bool _ready = false;
  String? _error;
  String _latex = '';

  @override
  void initState() {
    super.initState();
    _fallbackCtrl.text = widget.initialLatex;
    _initWebEditor();
  }

  @override
  void dispose() {
    _webMessageSub?.cancel();
    _fallbackCtrl.dispose();
    super.dispose();
  }

  Future<void> _initWebEditor() async {
    try {
      await _controller.initialize();
      await _controller.setBackgroundColor(_bg);
      _webMessageSub?.cancel();
      _webMessageSub = _controller.webMessage.listen(_handleWebMessage);
      final html = _buildHtml(widget.initialLatex);
      final url = Uri.dataFromString(
        html,
        mimeType: 'text/html',
        encoding: utf8,
      ).toString();
      await _controller.loadUrl(url);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '편집기 초기화 실패: $e';
        _loading = false;
      });
    }
  }

  void _handleWebMessage(dynamic message) {
    final raw = message is String ? message : message.toString();
    try {
      final obj = jsonDecode(raw);
      if (obj is! Map) return;
      final type = (obj['type'] ?? '').toString();
      if (type == 'ready') {
        final latex = (obj['latex'] ?? '').toString();
        if (!mounted) return;
        setState(() {
          _ready = true;
          _loading = false;
          _latex = latex;
        });
      } else if (type == 'latex_changed') {
        final latex = (obj['latex'] ?? '').toString();
        if (!mounted) return;
        setState(() => _latex = latex);
      } else if (type == 'error') {
        final msg = (obj['message'] ?? '알 수 없는 오류').toString();
        if (!mounted) return;
        setState(() {
          _error = msg;
          _loading = false;
        });
      }
    } catch (_) {
      // ignore malformed web message
    }
  }

  Future<void> _sendCommand(String command) async {
    if (!_ready) return;
    try {
      await _controller.postWebMessage(
        jsonEncode({'type': 'insert', 'command': command}),
      );
    } catch (_) {
      // ignore command failure
    }
  }

  Future<void> _requestCurrentLatex() async {
    if (!_ready) return;
    try {
      await _controller.postWebMessage(jsonEncode({'type': 'request_latex'}));
    } catch (_) {}
  }

  void _confirmInsert() async {
    if (_error != null) {
      Navigator.of(context).pop(_fallbackCtrl.text.trim());
      return;
    }
    await _requestCurrentLatex();
    if (!mounted) return;
    final latex = _latex.trim();
    if (latex.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('수식을 입력하세요.')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(latex);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _border),
      ),
      title: Text(
        widget.block ? '블록 수식 편집기' : '인라인 수식 편집기',
        style: const TextStyle(
          color: _text,
          fontSize: 18,
          fontWeight: FontWeight.w900,
        ),
      ),
      content: SizedBox(
        width: 860,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.block
                  ? r'위: 2차원 편집  /  아래: 1차원 LaTeX(자동 번역, $$...$$로 삽입)'
                  : r'위: 2차원 편집  /  아래: 1차원 LaTeX(자동 번역, \(...\)로 삽입)',
              style: const TextStyle(color: _textSub, fontSize: 12),
            ),
            const SizedBox(height: 10),
            _buildToolbar(),
            const SizedBox(height: 8),
            if (_error != null)
              _buildFallbackEditor()
            else
              _buildWebEditor(),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: _panel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _border),
              ),
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '1차원 LaTeX 표현 (자동 생성)',
                    style: TextStyle(color: _textSub, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 70),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: _field,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _border),
                    ),
                    child: SelectableText(
                      _latex.isEmpty ? r'{x}^{2}' : _latex,
                      style: const TextStyle(color: _text, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소', style: TextStyle(color: _textSub)),
        ),
        FilledButton(
          onPressed: _confirmInsert,
          style: FilledButton.styleFrom(backgroundColor: _accent),
          child: const Text('삽입', style: TextStyle(color: _text)),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    Widget btn(String label, String command) {
      return OutlinedButton(
        onPressed: (_ready && _error == null) ? () => _sendCommand(command) : null,
        style: OutlinedButton.styleFrom(
          foregroundColor: _text,
          side: const BorderSide(color: _border),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          minimumSize: const Size(0, 32),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        btn('지수', 'sup'),
        btn('아래첨자', 'sub'),
        btn('분수', 'frac'),
        btn('루트', 'sqrt'),
        btn('괄호', 'paren'),
        btn('+', 'op_plus'),
        btn('−', 'op_minus'),
        btn('×', 'op_times'),
        btn('÷', 'op_div'),
        btn('·', 'op_cdot'),
        btn('=', 'op_eq'),
        btn('<', 'op_lt'),
        btn('>', 'op_gt'),
        btn('≤', 'op_leq'),
        btn('≥', 'op_geq'),
        btn('≠', 'op_neq'),
        btn('±', 'op_pm'),
        btn('∓', 'op_mp'),
        btn('α', 'alpha'),
        btn('β', 'beta'),
        btn('γ', 'gamma'),
        btn('π', 'pi'),
        btn('θ', 'theta'),
        btn('행렬', 'matrix2'),
      ],
    );
  }

  Widget _buildWebEditor() {
    return Container(
      height: 320,
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Webview(_controller),
            if (_loading)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0xAA0B1112),
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFallbackEditor() {
    return Container(
      height: 320,
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _error ?? '편집기 오류',
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
          ),
          const SizedBox(height: 10),
          const Text(
            '텍스트 모드로 입력합니다.',
            style: TextStyle(color: _textSub, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _fallbackCtrl,
              expands: true,
              minLines: null,
              maxLines: null,
              style: const TextStyle(color: _text, fontSize: 14),
              cursorColor: _accent,
              inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
              decoration: InputDecoration(
                hintText: r'{x}^{2}, \frac{a}{b}, \sqrt{x}',
                hintStyle: const TextStyle(color: _textSub, fontSize: 13),
                filled: true,
                fillColor: _field,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _accent, width: 1.2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buildHtml(String initialLatex) {
    final encodedInitial = jsonEncode(initialLatex);
    return '''
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta http-equiv="Content-Security-Policy" content="default-src 'self' data: https: 'unsafe-inline' 'unsafe-eval';">
    <script defer src="https://unpkg.com/mathlive"></script>
    <style>
      html, body {
        margin: 0;
        width: 100%;
        height: 100%;
        background: #10171A;
        color: #EAF2F2;
        font-family: "Pretendard", "Noto Sans KR", sans-serif;
      }
      .root {
        box-sizing: border-box;
        width: 100%;
        height: 100%;
        padding: 10px;
      }
      math-field {
        width: 100%;
        min-height: 220px;
        border: 1px solid #223131;
        border-radius: 10px;
        background: #15171C;
        color: #EAF2F2;
        padding: 10px;
        font-size: 28px;
      }
      .hint {
        margin-top: 8px;
        color: #9FB3B3;
        font-size: 12px;
      }
    </style>
  </head>
  <body>
    <div class="root">
      <math-field id="mf"></math-field>
      <div class="hint">직접 입력하거나 상단 버튼(연산자·지수·분수·루트·행렬 등)을 사용하세요.</div>
    </div>
    <script>
      const initialLatex = $encodedInitial;
      let mf = null;
      const bridge = window.chrome && window.chrome.webview ? window.chrome.webview : null;

      function post(obj) {
        if (!bridge) return;
        try { bridge.postMessage(JSON.stringify(obj)); } catch (_) {}
      }

      function currentLatex() {
        try {
          if (!mf) return '';
          return (mf.value || '').toString();
        } catch (_) {
          return '';
        }
      }

      function emitLatex() {
        post({ type: 'latex_changed', latex: currentLatex() });
      }

      function insertLatex(latex) {
        if (!mf) return;
        try { mf.focus(); } catch (_) {}
        try {
          if (typeof mf.insert === 'function') {
            mf.insert(latex);
            emitLatex();
            return;
          }
        } catch (_) {}
        try {
          if (typeof mf.executeCommand === 'function') {
            mf.executeCommand(['insert', latex]);
            emitLatex();
            return;
          }
        } catch (_) {}
        try {
          mf.value = (mf.value || '') + latex;
        } catch (_) {}
        emitLatex();
      }

      function applyCommand(command) {
        switch (command) {
          case 'sup': insertLatex('^{#?}'); break;
          case 'sub': insertLatex('_{#?}'); break;
          case 'frac': insertLatex('\\\\frac{#?}{#?}'); break;
          case 'sqrt': insertLatex('\\\\sqrt{#?}'); break;
          case 'paren': insertLatex('\\\\left(#?\\\\right)'); break;
          case 'op_plus': insertLatex('+'); break;
          case 'op_minus': insertLatex('-'); break;
          case 'op_times': insertLatex('\\\\times'); break;
          case 'op_div': insertLatex('\\\\div'); break;
          case 'op_cdot': insertLatex('\\\\cdot'); break;
          case 'op_eq': insertLatex('='); break;
          case 'op_lt': insertLatex('<'); break;
          case 'op_gt': insertLatex('>'); break;
          case 'op_leq': insertLatex('\\\\leq'); break;
          case 'op_geq': insertLatex('\\\\geq'); break;
          case 'op_neq': insertLatex('\\\\neq'); break;
          case 'op_pm': insertLatex('\\\\pm'); break;
          case 'op_mp': insertLatex('\\\\mp'); break;
          case 'alpha': insertLatex('\\\\alpha'); break;
          case 'beta': insertLatex('\\\\beta'); break;
          case 'gamma': insertLatex('\\\\gamma'); break;
          case 'pi': insertLatex('\\\\pi'); break;
          case 'theta': insertLatex('\\\\theta'); break;
          case 'matrix2':
            insertLatex('\\\\begin{bmatrix}#? & #? \\\\\\\\ #? & #?\\\\end{bmatrix}');
            break;
          default:
            break;
        }
      }

      function initMathField() {
        try {
          mf = document.getElementById('mf');
          if (!mf) {
            post({ type: 'error', message: 'math-field를 찾을 수 없습니다.' });
            return;
          }
          try {
            if (typeof mf.setOptions === 'function') {
              mf.setOptions({ smartMode: true, smartFence: true, virtualKeyboardMode: 'off' });
            }
          } catch (_) {}
          try { mf.value = initialLatex || ''; } catch (_) {}
          mf.addEventListener('input', emitLatex);
          emitLatex();
          post({ type: 'ready', latex: currentLatex() });
        } catch (e) {
          post({ type: 'error', message: String(e) });
        }
      }

      if (bridge) {
        bridge.addEventListener('message', (event) => {
          try {
            const obj = typeof event.data === 'string' ? JSON.parse(event.data) : event.data;
            if (!obj || typeof obj !== 'object') return;
            if (obj.type === 'insert' && obj.command) {
              applyCommand(String(obj.command));
            } else if (obj.type === 'request_latex') {
              emitLatex();
            }
          } catch (_) {}
        });
      }

      if (window.customElements && customElements.whenDefined) {
        customElements.whenDefined('math-field')
          .then(initMathField)
          .catch((e) => post({ type: 'error', message: String(e) }));
      } else {
        setTimeout(initMathField, 300);
      }
    </script>
  </body>
</html>
''';
  }
}
