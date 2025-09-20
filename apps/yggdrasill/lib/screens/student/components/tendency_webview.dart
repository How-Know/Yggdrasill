import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_windows/webview_windows.dart';

class TendencyWebView extends StatefulWidget {
  final String? studentId;
  const TendencyWebView({super.key, this.studentId});

  @override
  State<TendencyWebView> createState() => _TendencyWebViewState();
}

class _TendencyWebViewState extends State<TendencyWebView> {
  final WebviewController _controller = WebviewController();
  bool _initialized = false;
  String? _baseUrl;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _controller.initialize();
    final prefs = await SharedPreferences.getInstance();
    final base = prefs.getString('survey_base_url') ?? 'http://localhost:5173';
    setState(() {
      _baseUrl = base;
      _initialized = true;
    });
    final sid = widget.studentId ?? '';
    final url = Uri.parse('$base/take?theme=dark&sid=$sid').toString();
    await _controller.loadUrl(url);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Text('설문(웹) · ${_baseUrl}', style: const TextStyle(color: Colors.white54, fontSize: 16)),
              const Spacer(),
              IconButton(
                tooltip: '관리자',
                onPressed: () {
                  final base = _baseUrl ?? '';
                  final url = Uri.parse('$base/?page=admin&hideTopbar=1').toString();
                  _controller.loadUrl(url);
                },
                icon: const Icon(Icons.admin_panel_settings, color: Colors.white70, size: 30),
              ),
              IconButton(
                tooltip: '새로고침',
                onPressed: () => _controller.reload(),
                icon: const Icon(Icons.refresh, color: Colors.white70, size: 30),
              ),
              IconButton(
                tooltip: '뒤로가기',
                onPressed: () => _controller.goBack(),
                icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 30),
              ),
              IconButton(
                tooltip: '앞으로가기',
                onPressed: () => _controller.goForward(),
                icon: const Icon(Icons.arrow_forward, color: Colors.white70, size: 30),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white12),
        Expanded(child: Webview(_controller)),
      ],
    );
  }
}







