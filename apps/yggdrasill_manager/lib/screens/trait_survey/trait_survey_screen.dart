import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_windows/webview_windows.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';

import '../../services/auth_service.dart';

class TraitSurveyScreen extends StatefulWidget {
  const TraitSurveyScreen({super.key});

  @override
  State<TraitSurveyScreen> createState() => _TraitSurveyScreenState();
}

class _TraitSurveyScreenState extends State<TraitSurveyScreen> {
  static const _kPrefKeyBaseUrl = 'survey_base_url';

  final WebviewController _controller = WebviewController();
  StreamSubscription? _webMessageSub;
  bool _initialized = false;
  bool _loading = true;
  String? _error;
  String _baseUrl = 'http://localhost:5173';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _baseUrl = (prefs.getString(_kPrefKeyBaseUrl) ?? 'http://localhost:5173').trim();
      if (_baseUrl.isEmpty) _baseUrl = 'http://localhost:5173';
      _baseUrl = _baseUrl.replaceAll(RegExp(r'\/+$'), '');

      await _controller.initialize();
      await _controller.setBackgroundColor(const Color(0xFF0B1112));

      _webMessageSub?.cancel();
      _webMessageSub = _controller.webMessage.listen((message) async {
        try {
          final raw = message;
          final obj = raw is String ? jsonDecode(raw) : (raw is Map ? raw : jsonDecode(raw.toString()));
          if (obj is! Map) return;
          if (obj['type'] != 'download_file') return;
          final filename = (obj['filename'] ?? 'export.xlsx').toString();
          final b64 = (obj['base64'] ?? '').toString();
          if (b64.isEmpty) return;

          final bytes = base64Decode(b64);
          final path = await FilePicker.platform.saveFile(
            dialogTitle: '엑셀 저장',
            fileName: filename,
            type: FileType.custom,
            allowedExtensions: const ['xlsx'],
          );
          if (path == null) return;

          final file = File(path);
          await file.writeAsBytes(bytes, flush: true);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('저장 완료: $path'), backgroundColor: const Color(0xFF2E7D32)),
          );

          // optional: notify web
          try {
            await _controller.postWebMessage(jsonEncode({'type':'download_result','ok': true,'path': path}));
          } catch (_) {}
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('저장 실패: $e'), backgroundColor: const Color(0xFFD32F2F)),
          );
        }
      });

      // ✅ survey-web은 window.__YGG_SUPABASE_URL / window.__YGG_SUPABASE_ANON_KEY 주입을 지원함
      // manager는 AuthService가 env.local.json/dart-define에서 읽어온 값을 사용한다.
      final injectedUrl = AuthService.supabaseUrl;
      final injectedKey = AuthService.supabaseAnonKey;
      if (injectedUrl.isNotEmpty && injectedKey.isNotEmpty) {
        await _controller.addScriptToExecuteOnDocumentCreated(
          "try { window.__YGG_SUPABASE_URL = ${jsonEncode(injectedUrl)}; window.__YGG_SUPABASE_ANON_KEY = ${jsonEncode(injectedKey)}; } catch(e) {}",
        );
      }

      await _controller.loadUrl('$_baseUrl/admin.html');

      if (!mounted) return;
      setState(() {
        _initialized = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _reload() async {
    try {
      await _controller.reload();
    } catch (_) {}
  }

  @override
  void dispose() {
    _webMessageSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Container(
      color: const Color(0xFF1F1F1F),
      child: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: Color(0xFF18181A),
              border: Border(bottom: BorderSide(color: Color(0xFF2A2A2A), width: 1)),
            ),
            child: Row(
              children: [
                const Text(
                  '성향조사 관리자',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                Text(
                  _baseUrl,
                  style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: '새로고침',
                  onPressed: _reload,
                  icon: Icon(Icons.refresh, color: Colors.white.withOpacity(0.7)),
                ),
              ],
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(
                    child: Text(
                      '로딩 실패: $_error',
                      style: TextStyle(color: Colors.redAccent.withOpacity(0.9)),
                    ),
                  )
                : _initialized
                    ? Webview(_controller)
                    : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

