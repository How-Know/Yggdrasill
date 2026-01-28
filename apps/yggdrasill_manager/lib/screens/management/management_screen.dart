import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ManagementScreen extends StatefulWidget {
  const ManagementScreen({super.key});

  @override
  State<ManagementScreen> createState() => _ManagementScreenState();
}

class _ManagementScreenState extends State<ManagementScreen> {
  final _openaiApiKeyController = TextEditingController();
  bool _isLoadingApiKey = false;
  bool _isSavingApiKey = false;

  static const _kPrefKeyBaseUrl = 'survey_base_url';
  final _surveyBaseUrlController = TextEditingController();
  bool _isLoadingSurveyBaseUrl = false;
  String? _surveyMsg;
  String? _docsMsg;

  @override
  void initState() {
    super.initState();
    _loadOpenAiApiKey();
    _loadSurveyBaseUrl();
  }

  @override
  void dispose() {
    _openaiApiKeyController.dispose();
    _surveyBaseUrlController.dispose();
    super.dispose();
  }

  String _normalizeBaseUrl(String raw) {
    var v = raw.trim();
    if (v.isEmpty) v = 'http://localhost:5173';
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'http://$v';
    }
    v = v.replaceAll(RegExp(r'\/+$'), '');
    return v;
  }

  Future<void> _loadSurveyBaseUrl() async {
    setState(() => _isLoadingSurveyBaseUrl = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final base = (prefs.getString(_kPrefKeyBaseUrl) ?? 'http://localhost:5173').trim();
      _surveyBaseUrlController.text = base;
    } catch (e) {
      debugPrint('survey_base_url 로드 실패: $e');
    } finally {
      if (mounted) setState(() => _isLoadingSurveyBaseUrl = false);
    }
  }

  Future<void> _saveSurveyBaseUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final base = _normalizeBaseUrl(_surveyBaseUrlController.text);
      await prefs.setString(_kPrefKeyBaseUrl, base);
      if (!mounted) return;
      setState(() => _surveyMsg = '저장되었습니다: $base');
    } catch (e) {
      if (!mounted) return;
      setState(() => _surveyMsg = '저장 실패: $e');
    }
  }

  Future<void> _openExternal(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      } else {
        throw Exception('지원하지 않는 플랫폼입니다.');
      }
      if (!mounted) return;
      setState(() => _surveyMsg = null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _surveyMsg = '열기 실패: $e');
    }
  }

  String _resolveAssessmentDocsRoot() {
    final sep = Platform.pathSeparator;
    final cwd = Directory.current.path;
    final parent = Directory(cwd).parent.path;
    final grandParent = Directory(parent).parent.path;
    final candidates = [
      '$cwd${sep}docs${sep}assessment',
      '$parent${sep}docs${sep}assessment',
      '$grandParent${sep}docs${sep}assessment',
    ];
    for (final path in candidates) {
      if (Directory(path).existsSync()) return path;
    }
    return candidates.first;
  }

  Future<void> _openLocalPath(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      if (!mounted) return;
      setState(() => _docsMsg = '경로를 찾을 수 없습니다: $path');
      return;
    }
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      } else {
        throw Exception('지원하지 않는 플랫폼입니다.');
      }
      if (!mounted) return;
      setState(() => _docsMsg = null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _docsMsg = '열기 실패: $e');
    }
  }

  void _openMarkdownViewer({required String title, required String path}) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      if (!mounted) return;
      setState(() => _docsMsg = '경로를 찾을 수 없습니다: $path');
      return;
    }
    setState(() => _docsMsg = null);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _MarkdownViewerPage(title: title, path: path),
      ),
    );
  }

  Future<void> _loadOpenAiApiKey() async {
    setState(() => _isLoadingApiKey = true);
    try {
      // platform_config 테이블에서 openai_api_key 가져오기
      final res = await Supabase.instance.client
          .from('platform_config')
          .select('config_value')
          .eq('config_key', 'openai_api_key')
          .maybeSingle();
      
      if (res != null && res['config_value'] != null) {
        _openaiApiKeyController.text = res['config_value'] as String;
      }
    } catch (e) {
      debugPrint('API 키 로드 실패: $e');
    } finally {
      setState(() => _isLoadingApiKey = false);
    }
  }

  Future<void> _saveOpenAiApiKey() async {
    final apiKey = _openaiApiKeyController.text.trim();
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('API 키를 입력하세요.'),
          backgroundColor: Color(0xFFD32F2F),
        ),
      );
      return;
    }

    setState(() => _isSavingApiKey = true);
    try {
      // platform_config 테이블에 upsert
      await Supabase.instance.client.from('platform_config').upsert({
        'config_key': 'openai_api_key',
        'config_value': apiKey,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('API 키가 저장되었습니다.'),
          backgroundColor: Color(0xFF2E7D32),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('저장 실패: $e'),
          backgroundColor: const Color(0xFFD32F2F),
        ),
      );
    } finally {
      setState(() => _isSavingApiKey = false);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchOwnersWithCounts() async {
    try {
      final res = await Supabase.instance.client.rpc('list_owners_with_teacher_counts');
      if (res is List) {
        return List<Map<String, dynamic>>.from(res);
      }
      if (res is Map && res.values.first is List) {
        return List<Map<String, dynamic>>.from(res.values.first as List);
      }
      return [];
    } catch (e) {
      debugPrint('소유자 조회 실패: $e');
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final docsRoot = _resolveAssessmentDocsRoot();
    final sep = Platform.pathSeparator;
    final docsReadme = '$docsRoot${sep}README.md';
    final docsModel = '$docsRoot${sep}model.md';
    final docsPhilosophy = '$docsRoot${sep}philosophy.md';
    final docsTodo = '$docsRoot${sep}TODO.md';
    return Container(
      color: const Color(0xFF1F1F1F),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '설정',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '학원 및 소유자 관리 / 성향조사 웹 설정',
            style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 14),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 성향조사 웹 설정
                      Container(
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          color: const Color(0xFF18181A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2A2A2A)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '성향조사 웹',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '설문/문항 관리자 페이지 주소를 설정합니다.',
                              style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 13),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _surveyBaseUrlController,
                                    enabled: !_isLoadingSurveyBaseUrl,
                                    style: const TextStyle(color: Colors.white),
                                    decoration: InputDecoration(
                                      labelText: '설문 웹 Base URL',
                                      labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                                      hintText: '예: http://localhost:5173',
                                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
                                      filled: true,
                                      fillColor: const Color(0xFF1F1F1F),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide(color: const Color(0xFF64B5F6).withOpacity(0.7)),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ElevatedButton(
                                  onPressed: _isLoadingSurveyBaseUrl ? null : _saveSurveyBaseUrl,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF1976D2),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  child: const Text('저장', style: TextStyle(fontWeight: FontWeight.w800)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Builder(builder: (context) {
                              final base = _normalizeBaseUrl(_surveyBaseUrlController.text);
                              final adminUrl = '$base/admin.html';
                              final surveyUrl = '$base/';
                              return Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  ElevatedButton.icon(
                                    onPressed: () => _openExternal(adminUrl),
                                    icon: const Icon(Icons.admin_panel_settings_outlined),
                                    label: const Text('관리자 페이지 열기', style: TextStyle(fontWeight: FontWeight.w800)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF2A2A2A),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () => _openExternal(surveyUrl),
                                    icon: const Icon(Icons.open_in_new),
                                    label: const Text('설문 페이지 열기', style: TextStyle(fontWeight: FontWeight.w800)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white,
                                      side: const BorderSide(color: Color(0xFF2A2A2A)),
                                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                ],
                              );
                            }),
                            if (_surveyMsg != null) ...[
                              const SizedBox(height: 10),
                              Text(_surveyMsg!, style: const TextStyle(color: Color(0xFF64B5F6), fontSize: 13)),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 지표 관리
                      Container(
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          color: const Color(0xFF18181A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2A2A2A)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '지표 관리',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '학생 이해 프레임워크 및 지표 문서를 빠르게 열어볼 수 있습니다.',
                              style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 13),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '문서 위치: $docsRoot',
                              style: const TextStyle(color: Color(0xFF8F8F8F), fontSize: 12),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: () => _openLocalPath(docsRoot),
                                  icon: const Icon(Icons.folder_open),
                                  label: const Text('폴더 열기', style: TextStyle(fontWeight: FontWeight.w800)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF2A2A2A),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => _AssessmentStructurePage(docsRoot: docsRoot),
                                    ),
                                  ),
                                  icon: const Icon(Icons.description_outlined),
                                  label: const Text('구조 요약', style: TextStyle(fontWeight: FontWeight.w800)),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(color: Color(0xFF2A2A2A)),
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => _openMarkdownViewer(title: '정의/근거', path: docsModel),
                                  icon: const Icon(Icons.account_tree_outlined),
                                  label: const Text('정의/근거', style: TextStyle(fontWeight: FontWeight.w800)),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(color: Color(0xFF2A2A2A)),
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => _openMarkdownViewer(title: '철학', path: docsPhilosophy),
                                  icon: const Icon(Icons.auto_stories_outlined),
                                  label: const Text('철학', style: TextStyle(fontWeight: FontWeight.w800)),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(color: Color(0xFF2A2A2A)),
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => _openMarkdownViewer(title: 'TODO', path: docsTodo),
                                  icon: const Icon(Icons.checklist_outlined),
                                  label: const Text('TODO', style: TextStyle(fontWeight: FontWeight.w800)),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(color: Color(0xFF2A2A2A)),
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                              ],
                            ),
                            if (_docsMsg != null) ...[
                              const SizedBox(height: 10),
                              Text(_docsMsg!, style: const TextStyle(color: Color(0xFF64B5F6), fontSize: 13)),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 소유자 목록
                      Container(
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          color: const Color(0xFF18181A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2A2A2A)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '학원 및 소유자 목록',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 20),
                            FutureBuilder<List<Map<String, dynamic>>>(
                              future: _fetchOwnersWithCounts(),
                              builder: (context, snapshot) {
                                if (snapshot.connectionState == ConnectionState.waiting) {
                                  return const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Center(child: CircularProgressIndicator()),
                                  );
                                }

                                final rows = snapshot.data ?? const [];
                                if (rows.isEmpty) {
                                  return Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Center(
                                      child: Column(
                                        children: [
                                          Icon(
                                            Icons.business_outlined,
                                            size: 48,
                                            color: Colors.white.withOpacity(0.3),
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            '등록된 학원이 없습니다.',
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(0.5),
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }

                                return Column(
                                  children: [
                                    // 테이블 헤더
                                    Container(
                                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1F1F1F),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Row(
                                        children: [
                                          Expanded(
                                            flex: 2,
                                            child: Text(
                                              '학원명',
                                              style: TextStyle(
                                                color: Color(0xFFB3B3B3),
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 2,
                                            child: Text(
                                              '소유자 이메일',
                                              style: TextStyle(
                                                color: Color(0xFFB3B3B3),
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 120,
                                            child: Text(
                                              '선생님 수',
                                              style: TextStyle(
                                                color: Color(0xFFB3B3B3),
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 120,
                                            child: Text(
                                              '접근',
                                              style: TextStyle(
                                                color: Color(0xFFB3B3B3),
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    // 테이블 행
                                    ...rows.map((r) => Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1F1F1F),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            flex: 2,
                                            child: Text(
                                              (r['academy_name'] as String?) ?? '-',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 15,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 2,
                                            child: Text(
                                              (r['owner_email'] as String?) ?? '-',
                                              style: const TextStyle(
                                                color: Color(0xFFB3B3B3),
                                                fontSize: 15,
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 120,
                                            child: Text(
                                              '${r['teacher_count'] ?? 0}명',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 15,
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 120,
                                            child: Center(
                                              child: Switch.adaptive(
                                                value: !(r['is_blocked'] as bool? ?? false),
                                                onChanged: (v) async {
                                                  try {
                                                    await Supabase.instance.client.rpc(
                                                      'set_owner_blocked',
                                                      params: {
                                                        'p_owner_user_id': r['owner_user_id'],
                                                        'p_blocked': !v,
                                                      },
                                                    );
                                                    setState(() {});
                                                    if (!mounted) return;
                                                    ScaffoldMessenger.of(context).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          v ? '접근이 허용되었습니다.' : '접근이 차단되었습니다.',
                                                        ),
                                                        backgroundColor: v
                                                            ? const Color(0xFF2E7D32)
                                                            : const Color(0xFFD32F2F),
                                                      ),
                                                    );
                                                  } catch (e) {
                                                    if (!mounted) return;
                                                    ScaffoldMessenger.of(context).showSnackBar(
                                                      SnackBar(
                                                        content: Text('변경 실패: $e'),
                                                        backgroundColor: const Color(0xFFD32F2F),
                                                      ),
                                                    );
                                                  }
                                                },
                                                activeColor: const Color(0xFF1976D2),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(height: 24),
                      
                      // OpenAI API 키 설정
                      Container(
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          color: const Color(0xFF18181A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2A2A2A)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.key, color: Color(0xFF1976D2), size: 24),
                                const SizedBox(width: 12),
                                const Text(
                                  'OpenAI API 키',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '관리자가 설정한 API 키는 서버에 안전하게 저장되며, 모든 앱에서 자동으로 사용됩니다.',
                              style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 13),
                            ),
                            const SizedBox(height: 20),
                            if (_isLoadingApiKey)
                              const Center(child: CircularProgressIndicator())
                            else
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _openaiApiKeyController,
                                      enabled: !_isSavingApiKey,
                                      obscureText: true,
                                      decoration: InputDecoration(
                                        hintText: 'sk-proj-...',
                                        hintStyle: const TextStyle(color: Color(0xFF666666)),
                                        filled: true,
                                        fillColor: const Color(0xFF2A2A2A),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8),
                                          borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8),
                                          borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8),
                                          borderSide: const BorderSide(color: Color(0xFF1976D2)),
                                        ),
                                      ),
                                      style: const TextStyle(color: Colors.white),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  ElevatedButton.icon(
                                    onPressed: _isSavingApiKey ? null : _saveOpenAiApiKey,
                                    icon: _isSavingApiKey
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                            ),
                                          )
                                        : const Icon(Icons.save, size: 18),
                                    label: const Text('저장'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF1976D2),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(height: 24),
                      
                      // 구독 관리 (준비 중)
                      Container(
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          color: const Color(0xFF18181A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2A2A2A)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '구독 관리',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Center(
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.subscriptions_outlined,
                                    size: 48,
                                    color: Colors.white.withOpacity(0.3),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    '추후 구현 예정입니다.',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkdownViewerPage extends StatelessWidget {
  const _MarkdownViewerPage({
    required this.title,
    required this.path,
  });

  final String title;
  final String path;

  Future<String> _loadContent() async {
    return File(path).readAsString();
  }

  MarkdownStyleSheet _buildStyle(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: text.bodyMedium?.copyWith(color: Colors.white, height: 1.5),
      h1: text.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
      h2: text.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
      h3: text.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
      h4: text.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
      code: text.bodyMedium?.copyWith(color: Colors.white),
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(8),
      ),
      blockquoteDecoration: BoxDecoration(
        color: const Color(0xFF232323),
        borderRadius: BorderRadius.circular(6),
      ),
      blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      blockquote: text.bodyMedium?.copyWith(color: const Color(0xFFB3B3B3)),
      a: const TextStyle(color: Color(0xFF64B5F6)),
      listBullet: const TextStyle(color: Colors.white),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF18181A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: FutureBuilder<String>(
        future: _loadContent(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                '문서를 불러오지 못했습니다: ${snapshot.error}',
                style: const TextStyle(color: Color(0xFFB3B3B3)),
                textAlign: TextAlign.center,
              ),
            );
          }
          final data = snapshot.data ?? '';
          if (data.trim().isEmpty) {
            return const Center(
              child: Text('문서가 비어 있습니다.', style: TextStyle(color: Color(0xFFB3B3B3))),
            );
          }
          return Markdown(
            data: data,
            styleSheet: _buildStyle(context),
            padding: const EdgeInsets.all(24),
          );
        },
      ),
    );
  }
}

class _StructureNode {
  const _StructureNode({
    required this.title,
    this.docPath,
    this.children = const [],
  });

  final String title;
  final String? docPath;
  final List<_StructureNode> children;
}

class _AssessmentStructurePage extends StatelessWidget {
  const _AssessmentStructurePage({required this.docsRoot});

  final String docsRoot;

  String _docPath(List<String> parts) {
    return [docsRoot, ...parts].join(Platform.pathSeparator);
  }

  String _termPath(String relative) {
    final segments = relative.split('/');
    return _docPath(['terms', ...segments]);
  }

  void _openDoc(BuildContext context, String title, String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('문서를 찾을 수 없습니다: $path'),
          backgroundColor: const Color(0xFFD32F2F),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _MarkdownViewerPage(title: title, path: path),
      ),
    );
  }

  List<_StructureNode> _buildTree() {
    return [
      _StructureNode(
        title: '통제 어려운 것 (비개입 변수)',
        docPath: _termPath('non_intervention.md'),
        children: [
          _StructureNode(
            title: '마음',
            docPath: _termPath('non_intervention/mind.md'),
            children: [
              _StructureNode(
                title: '기질',
                docPath: _termPath('non_intervention/mind_temperament.md'),
                children: [
                  _StructureNode(
                    title: '정서 반응성',
                    docPath: _termPath('non_intervention/mind_emotional_reactivity.md'),
                  ),
                ],
              ),
              _StructureNode(
                title: '성향',
                docPath: _termPath('non_intervention/mind_tendency.md'),
                children: [
                  _StructureNode(
                    title: '자율성 축 (자주적 ↔ 의존적)',
                    docPath: _termPath('non_intervention/mind_tendency_axis_autonomy.md'),
                  ),
                  _StructureNode(
                    title: '인지 처리 축 (논리 ↔ 직관)',
                    docPath: _termPath('non_intervention/mind_tendency_axis_cognitive_processing.md'),
                  ),
                  _StructureNode(
                    title: '실행 스타일 축 (계획 ↔ 즉흥)',
                    docPath: _termPath('non_intervention/mind_tendency_axis_execution_style.md'),
                  ),
                  _StructureNode(
                    title: '도전 반응 축 (도전 ↔ 회피)',
                    docPath: _termPath('non_intervention/mind_tendency_axis_challenge_response.md'),
                  ),
                  _StructureNode(
                    title: '16가지 성향 프로파일',
                    docPath: _termPath('non_intervention/mind_tendency_profiles.md'),
                  ),
                ],
              ),
              _StructureNode(
                title: '신념',
                docPath: _termPath('non_intervention/mind_belief_identity_system.md'),
                children: [
                  _StructureNode(
                    title: '신념 체계',
                    docPath: _termPath('non_intervention/mind_belief_system.md'),
                    children: [
                      _StructureNode(
                        title: '수학 능력에 대한 암묵적 신념',
                        docPath: _termPath('non_intervention/mind_implicit_belief_math_ability.md'),
                      ),
                      _StructureNode(
                        title: '통제 가능성 신념',
                        docPath: _termPath('non_intervention/mind_controllability_belief.md'),
                        children: [
                          _StructureNode(
                            title: '노력–성과 연결 신념',
                            docPath: _termPath('non_intervention/mind_effort_outcome_belief.md'),
                          ),
                          _StructureNode(
                            title: '주도성 인식',
                            docPath: _termPath('non_intervention/mind_self_directedness_belief.md'),
                          ),
                        ],
                      ),
                      _StructureNode(
                        title: '실패 해석 신념',
                        docPath: _termPath('non_intervention/mind_failure_attribution_belief.md'),
                      ),
                      _StructureNode(
                        title: '질문/이해에 대한 신념',
                        docPath: _termPath('non_intervention/mind_epistemic_belief_math.md'),
                      ),
                      _StructureNode(
                        title: '회복 기대 신념',
                        docPath: _termPath('non_intervention/mind_resilience_expectancy_belief.md'),
                      ),
                    ],
                  ),
                  _StructureNode(
                    title: '자기 개념',
                    docPath: _termPath('non_intervention/mind_self_concept.md'),
                  ),
                  _StructureNode(
                    title: '정체성',
                    docPath: _termPath('non_intervention/mind_identity.md'),
                  ),
                ],
              ),
            ],
          ),
          _StructureNode(
            title: '재능',
            docPath: _termPath('non_intervention/aptitude.md'),
            children: [
              _StructureNode(
                title: '처리 속도',
                docPath: _termPath('non_intervention/aptitude_processing_speed.md'),
              ),
              _StructureNode(
                title: '작업기억 용량',
                docPath: _termPath('non_intervention/aptitude_working_memory.md'),
              ),
              _StructureNode(
                title: '공간 능력',
                docPath: _termPath('non_intervention/aptitude_spatial_ability.md'),
              ),
            ],
          ),
          _StructureNode(
            title: '운',
            docPath: _termPath('non_intervention/chance.md'),
            children: [
              _StructureNode(
                title: '만난 문제 유형',
                docPath: _termPath('non_intervention/chance_problem_type.md'),
              ),
              _StructureNode(
                title: '시험 당일 컨디션',
                docPath: _termPath('non_intervention/chance_test_day_condition.md'),
              ),
              _StructureNode(
                title: '우연한 성공/실패 경험',
                docPath: _termPath('non_intervention/chance_accidental_experience.md'),
              ),
            ],
          ),
          _StructureNode(
            title: '학습 환경',
            docPath: _termPath('non_intervention/learning_environment.md'),
            children: [
              _StructureNode(
                title: '교사',
                docPath: _termPath('non_intervention/learning_environment_teacher.md'),
              ),
              _StructureNode(
                title: '커리큘럼',
                docPath: _termPath('non_intervention/learning_environment_curriculum.md'),
              ),
              _StructureNode(
                title: '가정/학교 맥락',
                docPath: _termPath('non_intervention/learning_environment_home_school_context.md'),
              ),
            ],
          ),
        ],
      ),
      _StructureNode(
        title: '통제 가능한 것 (개입 가능 변수)',
        docPath: _termPath('intervention.md'),
        children: [
          _StructureNode(
            title: '통합적 수학 역량',
            docPath: _termPath('intervention/integrated_math_competency.md'),
            children: [
              _StructureNode(
                title: '능력 지표',
                docPath: _termPath('ability_indicators.md'),
                children: [
                  _StructureNode(
                    title: '질문 구성 능력',
                    docPath: _termPath('intervention/math_question_formulation.md'),
                  ),
                  _StructureNode(
                    title: '사고력',
                    docPath: _termPath('intervention/math_reasoning.md'),
                  ),
                  _StructureNode(
                    title: '논리력',
                    docPath: _termPath('intervention/math_logic.md'),
                  ),
                  _StructureNode(
                    title: '문제해결력',
                    docPath: _termPath('intervention/math_problem_solving.md'),
                  ),
                  _StructureNode(
                    title: '메타인지',
                    docPath: _termPath('intervention/math_metacognition.md'),
                  ),
                ],
              ),
              _StructureNode(
                title: '상태 지표',
                docPath: _termPath('state_indicators.md'),
                children: [
                  _StructureNode(
                    title: '없음(원칙적으로)',
                    docPath: _termPath('intervention/math_state_none.md'),
                  ),
                ],
              ),
            ],
          ),
          _StructureNode(
            title: '정신',
            docPath: _termPath('intervention/mental.md'),
            children: [
              _StructureNode(
                title: '능력 지표',
                docPath: _termPath('ability_indicators.md'),
                children: [
                  _StructureNode(
                    title: '정서 조절 능력',
                    docPath: _termPath('intervention/mental_emotion_regulation.md'),
                  ),
                  _StructureNode(
                    title: '동기 조절 능력',
                    docPath: _termPath('intervention/mental_motivation_regulation.md'),
                  ),
                  _StructureNode(
                    title: '인지적 회복력',
                    docPath: _termPath('intervention/mental_cognitive_resilience.md'),
                  ),
                  _StructureNode(
                    title: '과제 가치 인식',
                    docPath: _termPath('intervention/mental_task_value.md'),
                  ),
                  _StructureNode(
                    title: '내재적 동기',
                    docPath: _termPath('intervention/mental_intrinsic_motivation.md'),
                  ),
                  _StructureNode(
                    title: '지속 의지',
                    docPath: _termPath('intervention/mental_persistence_intent.md'),
                  ),
                ],
              ),
              _StructureNode(
                title: '상태 지표',
                docPath: _termPath('state_indicators.md'),
                children: [
                  _StructureNode(
                    title: '불안 수준',
                    docPath: _termPath('intervention/mental_anxiety_level.md'),
                  ),
                  _StructureNode(
                    title: '흥미',
                    docPath: _termPath('intervention/mental_interest.md'),
                  ),
                  _StructureNode(
                    title: '즐거움',
                    docPath: _termPath('intervention/mental_enjoyment.md'),
                  ),
                  _StructureNode(
                    title: '좌절',
                    docPath: _termPath('intervention/mental_frustration.md'),
                  ),
                  _StructureNode(
                    title: '자신감',
                    docPath: _termPath('intervention/mental_confidence.md'),
                  ),
                  _StructureNode(
                    title: '긴장',
                    docPath: _termPath('intervention/mental_tension.md'),
                  ),
                  _StructureNode(
                    title: '피로',
                    docPath: _termPath('intervention/mental_fatigue.md'),
                  ),
                ],
              ),
            ],
          ),
          _StructureNode(
            title: '행동',
            docPath: _termPath('intervention/behavior.md'),
            children: [
              _StructureNode(
                title: '능력 지표',
                docPath: _termPath('ability_indicators.md'),
                children: [
                  _StructureNode(
                    title: '전략 실행 능력',
                    docPath: _termPath('intervention/behavior_strategy_execution.md'),
                  ),
                  _StructureNode(
                    title: '오류 회복 능력',
                    docPath: _termPath('intervention/behavior_error_recovery.md'),
                  ),
                  _StructureNode(
                    title: '지속성',
                    docPath: _termPath('intervention/behavior_persistence.md'),
                    children: [
                      _StructureNode(
                        title: '문제 지속성',
                        docPath: _termPath('intervention/behavior_persistence.md'),
                      ),
                    ],
                  ),
                ],
              ),
              _StructureNode(
                title: '상태 지표',
                docPath: _termPath('state_indicators.md'),
                children: [
                  _StructureNode(
                    title: '시도 빈도',
                    docPath: _termPath('intervention/behavior_attempt_frequency.md'),
                  ),
                  _StructureNode(
                    title: '회피 반응',
                    docPath: _termPath('intervention/behavior_avoidance_response.md'),
                  ),
                  _StructureNode(
                    title: '질문 빈도',
                    docPath: _termPath('intervention/behavior_question_frequency.md'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      _StructureNode(
        title: '성과 상태 (결과 변수)',
        docPath: _termPath('performance_state.md'),
        children: [
          _StructureNode(
            title: '1차 분해 (양상)',
            children: [
              _StructureNode(
                title: '안정성',
                docPath: _termPath('performance/axis_stability.md'),
              ),
              _StructureNode(
                title: '범위',
                docPath: _termPath('performance/axis_coverage.md'),
              ),
              _StructureNode(
                title: '전이성',
                docPath: _termPath('performance/axis_transfer.md'),
              ),
              _StructureNode(
                title: '지속성',
                docPath: _termPath('performance/axis_persistence.md'),
              ),
            ],
          ),
          _StructureNode(
            title: '2차 분해 (역량 발현)',
            children: [
              _StructureNode(
                title: '사고 발현 성과',
                docPath: _termPath('performance/expression_reasoning.md'),
              ),
              _StructureNode(
                title: '논리 발현 성과',
                docPath: _termPath('performance/expression_logic.md'),
              ),
              _StructureNode(
                title: '문제해결 발현 성과',
                docPath: _termPath('performance/expression_problem_solving.md'),
              ),
              _StructureNode(
                title: '질문 발현 성과',
                docPath: _termPath('performance/expression_question_formulation.md'),
              ),
              _StructureNode(
                title: '메타인지 발현 성과',
                docPath: _termPath('performance/expression_metacognition.md'),
              ),
            ],
          ),
          _StructureNode(
            title: '보조 지표',
            children: [
              _StructureNode(
                title: '점수',
                docPath: _termPath('performance/aux_score.md'),
              ),
              _StructureNode(
                title: '성취도',
                docPath: _termPath('performance/aux_achievement.md'),
              ),
              _StructureNode(
                title: '정답률',
                docPath: _termPath('performance/aux_accuracy.md'),
              ),
            ],
          ),
        ],
      ),
      _StructureNode(
        title: '내용 영역 (독립 축)',
        docPath: _termPath('content_domain.md'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tree = _buildTree();
    final readme = _docPath(['README.md']);
    final model = _docPath(['model.md']);
    final philosophy = _docPath(['philosophy.md']);

    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF18181A),
        title: const Text('구조 요약', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF18181A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '한눈에 보는 구조',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  '항목을 클릭하면 하위 지표가 펼쳐지고, 오른쪽 상세 버튼으로 문서를 엽니다.',
                  style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 12),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _openDoc(context, '구조 요약', readme),
                      icon: const Icon(Icons.description_outlined),
                      label: const Text('구조 요약 문서'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF2A2A2A)),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _openDoc(context, '정의/근거', model),
                      icon: const Icon(Icons.account_tree_outlined),
                      label: const Text('정의/근거'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF2A2A2A)),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _openDoc(context, '철학', philosophy),
                      icon: const Icon(Icons.auto_stories_outlined),
                      label: const Text('철학'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF2A2A2A)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF18181A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: Column(
              children: tree
                  .map(
                    (node) => _TreeNodeView(
                      node: node,
                      indent: 8,
                      defaultExpanded: true,
                      onOpen: (title, path) => _openDoc(context, title, path),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _TreeNodeView extends StatefulWidget {
  const _TreeNodeView({
    required this.node,
    required this.indent,
    required this.onOpen,
    this.defaultExpanded = false,
  });

  final _StructureNode node;
  final double indent;
  final bool defaultExpanded;
  final void Function(String title, String path) onOpen;

  @override
  State<_TreeNodeView> createState() => _TreeNodeViewState();
}

class _TreeNodeViewState extends State<_TreeNodeView> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.defaultExpanded;
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final hasChildren = node.children.isNotEmpty;
    final hasDoc = node.docPath != null;
    const lineColor = Color(0xFF2A2A2A);
    const leadingWidth = 28.0;
    final titleStyle = TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: hasChildren ? FontWeight.w700 : FontWeight.w500,
    );

    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.only(left: widget.indent, right: 12),
          minLeadingWidth: leadingWidth,
          horizontalTitleGap: 8,
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: hasChildren
              ? GestureDetector(
                  onTap: _toggleExpanded,
                  child: SizedBox(
                    width: leadingWidth,
                    height: leadingWidth,
                    child: Icon(
                      _expanded ? Icons.expand_more : Icons.chevron_right,
                      color: const Color(0xFF9E9E9E),
                      size: 20,
                    ),
                  ),
                )
              : const SizedBox(width: leadingWidth, height: leadingWidth),
          title: Text(node.title, style: titleStyle),
          trailing: hasDoc
              ? TextButton.icon(
                  onPressed: () => widget.onOpen(node.title, node.docPath!),
                  icon: const Icon(Icons.description_outlined, size: 16),
                  label: const Text('상세'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF9E9E9E),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                )
              : null,
          onTap: hasChildren ? _toggleExpanded : null,
        ),
        if (hasChildren && _expanded)
          Stack(
            children: [
              Positioned(
                left: widget.indent + (leadingWidth / 2),
                top: 0,
                bottom: 0,
                child: Container(width: 1, color: lineColor),
              ),
              Column(
                children: node.children
                    .map(
                      (child) => _TreeNodeView(
                        node: child,
                        indent: widget.indent + 16,
                        onOpen: widget.onOpen,
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
      ],
    );
  }
}

