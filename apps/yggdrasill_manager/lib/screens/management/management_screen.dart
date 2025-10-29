import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ManagementScreen extends StatefulWidget {
  const ManagementScreen({super.key});

  @override
  State<ManagementScreen> createState() => _ManagementScreenState();
}

class _ManagementScreenState extends State<ManagementScreen> {
  final _openaiApiKeyController = TextEditingController();
  bool _isLoadingApiKey = false;
  bool _isSavingApiKey = false;

  @override
  void initState() {
    super.initState();
    _loadOpenAiApiKey();
  }

  @override
  void dispose() {
    _openaiApiKeyController.dispose();
    super.dispose();
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
    return Container(
      color: const Color(0xFF1F1F1F),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '관리',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '학원 및 소유자 관리',
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

