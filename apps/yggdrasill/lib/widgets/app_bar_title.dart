import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../screens/settings/settings_screen.dart';
import 'dart:io' show Platform, HttpServer, File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:crypto/crypto.dart';
import '../services/data_manager.dart';
import '../models/teacher.dart';
import './teacher_registration_dialog.dart';

SupabaseClient? _safeClient() {
  try {
    return Supabase.instance.client;
  } catch (_) {
    return null;
  }
}

class AppBarTitle extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback? onRefresh;
  final VoidCallback? onSettings;
  final List<Widget>? actions;

  const AppBarTitle({
    Key? key,
    required this.title,
    this.onBack,
    this.onForward,
    this.onRefresh,
    this.onSettings,
    this.actions,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1F1F1F),
      padding: const EdgeInsets.only(top: 0, left: 0, right: 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 중앙 타이틀: 좌우 아이콘 폭과 무관하게 정확히 중앙
                Center(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // 왼쪽 아이콘들
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70),
                          onPressed: onBack ?? () {
                            if (Navigator.of(context).canPop()) {
                              Navigator.of(context).pop();
                            }
                          },
                          tooltip: '뒤로가기',
                        ),
                        IconButton(
                          icon: const Icon(Icons.arrow_forward_ios, color: Colors.white70),
                          onPressed: onForward,
                          tooltip: '앞으로가기',
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.white70),
                          onPressed: onRefresh,
                          tooltip: '새로고침',
                        ),
                      ],
                    ),
                  ),
                ),
                // 오른쪽 액션들
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (actions != null) ...actions!,
                        IconButton(
                          icon: const Icon(Icons.apps, color: Colors.white70),
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('앱스 버튼 클릭됨')),
                            );
                          },
                          tooltip: '앱스',
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings, color: Colors.white70),
                          onPressed: onSettings ?? () {
                            Navigator.of(context).push(
                              PageRouteBuilder(
                                pageBuilder: (context, animation, secondaryAnimation) => const SettingsScreen(),
                                transitionsBuilder: (context, animation, secondaryAnimation, child) {
                                  final isPop = animation.value < secondaryAnimation.value;
                                  final beginOffset = isPop ? Offset.zero : Offset(1.0, 0.0);
                                  final endOffset = isPop ? Offset(1.0, 0.0) : Offset.zero;
                                  final slideAnimation = Tween<Offset>(begin: beginOffset, end: endOffset)
                                      .chain(CurveTween(curve: Curves.easeInOut))
                                      .animate(animation);
                                  final fadeAnimation = Tween<double>(begin: 0.0, end: 1.0)
                                      .chain(CurveTween(curve: Curves.easeInOut))
                                      .animate(animation);
                                  return SlideTransition(
                                    position: slideAnimation,
                                    child: FadeTransition(
                                      opacity: fadeAnimation,
                                      child: child,
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                          tooltip: '설정',
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: InkWell(
                            onTap: () async {
                              final client = _safeClient();
                              final user = client?.auth.currentUser;
                              if (user == null) {
                                showDialog(
                                  context: context,
                                  barrierDismissible: true,
                                  builder: (ctx) => const _LoginDialog(),
                                );
                              } else {
                                await showDialog(
                                  context: context,
                                  barrierDismissible: true,
                                  builder: (ctx) => const _AccountDialog(),
                                );
                              }
                            },
                            child: FutureBuilder<Map<String, dynamic>>(
                              future: _ProfileStore.load(),
                              builder: (ctx, snap) {
                                final map = snap.data ?? const {'profiles':{}, 'activeEmail': null};
                                final user = _safeClient()?.auth.currentUser;
                                final activeEmail = (map['activeEmail'] as String?) ?? user?.email;
                                final info = (map['profiles'] as Map)[activeEmail] as Map? ?? {};
                                final avatarPath = (info['avatar'] as String?) ?? '';
                                final presetColor = (info['presetColor'] as String?) ?? '#2A2A2A';
                                final presetInitial = (info['presetInitial'] as String?) ?? '';
                                final displayName = (() {
                                  final list = DataManager.instance.teachersNotifier.value;
                                  try { return list.firstWhere((t) => t.email == activeEmail).name; } catch (_) { return (activeEmail ?? '').split('@').first; }
                                })();
                                final googleUrl = (activeEmail == user?.email)
                                  ? (user?.userMetadata?['avatar_url'] ?? user?.userMetadata?['picture']) as String?
                                  : null;
                                ImageProvider? img;
                                if (avatarPath.isNotEmpty) {
                                  if (avatarPath.startsWith('http')) { img = NetworkImage(avatarPath); }
                                  else if (File(avatarPath).existsSync()) { img = FileImage(File(avatarPath)); }
                                } else if (googleUrl != null && googleUrl.isNotEmpty) {
                                  img = NetworkImage(googleUrl);
                                }
                                final bg = _parseColor(presetColor);
                                final label = (presetInitial.isNotEmpty) ? presetInitial : _initials(displayName);
                                return CircleAvatar(
                                  radius: 16,
                                  backgroundColor: img == null ? bg : null,
                                  backgroundImage: img,
                                  child: img == null ? Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900)) : null,
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.black),
        ],
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(70);
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog();
  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF18181A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF2A2A2A))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 416),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('로그인', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white70),
                    tooltip: '닫기',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('기존 회원', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 6),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: '이메일',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A82D2))),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  hintText: '비밀번호',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2A82D2))),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off, color: Colors.white54),
                  ),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFFE53E3E), fontSize: 12)),
                ),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        final email = _emailController.text.trim();
                        final pw = _passwordController.text;
                        if (email.isEmpty || !email.contains('@')) { setState(() => _error = '이메일 형식을 확인하세요.'); return; }
                        if (pw.isEmpty || pw.length < 6) { setState(() => _error = '비밀번호는 6자 이상이어야 합니다.'); return; }
                        setState(() => _error = null);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('로그인(UI만 구현)')));
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1976D2),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('로그인', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1, color: Color(0xFF2A2A2A)),
              const SizedBox(height: 12),
              const Text('회원가입', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final client = _safeClient();
                      if (client == null) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Supabase가 초기화되지 않았습니다. 실행 시 --dart-define로 URL/KEY를 전달하세요.')));
                        return;
                      }
                      if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
                        // 1) 데스크톱: 로컬 콜백 서버를 직접 띄우고 코드 교환 수행
                        final server = await HttpServer.bind('127.0.0.1', 3000);
                        // 인증 시작 (브라우저로 이동)
                        await client.auth.signInWithOAuth(
                          OAuthProvider.google,
                          redirectTo: 'http://localhost:3000',
                        );
                        // 2) 첫 요청 수신 후 코드 교환
                        final req = await server.first;
                        final uri = req.uri;
                        final code = uri.queryParameters['code'];
                        if (code != null && code.isNotEmpty) {
                          try {
                            await client.auth.exchangeCodeForSession(code);
                            req.response
                              ..statusCode = 200
                              ..headers.set('Content-Type', 'text/html; charset=utf-8')
                              ..write('<html><body style="font-family:sans-serif;background:#111;color:#eee;text-align:center;padding:32px;">로그인이 완료되었습니다. 이 창을 닫으셔도 됩니다.</body></html>');
                          } catch (e) {
                            req.response
                              ..statusCode = 500
                              ..headers.set('Content-Type', 'text/plain; charset=utf-8')
                              ..write('세션 교환 실패: $e');
                          }
                        } else {
                          req.response
                            ..statusCode = 400
                            ..headers.set('Content-Type', 'text/plain; charset=utf-8')
                            ..write('유효하지 않은 콜백');
                        }
                        await req.response.close();
                        await server.close(force: true);
                        if (mounted) Navigator.of(context).pop();
                      } else {
                        // 3) 모바일/웹: 기본 플로우(스킴/기본 콜백)
                        final redirectUrl = (Platform.isAndroid || Platform.isIOS)
                            ? 'yggdrasill://callback'
                            : null;
                        await client.auth.signInWithOAuth(
                          OAuthProvider.google,
                          redirectTo: redirectUrl,
                        );
                        if (mounted) Navigator.of(context).pop();
                      }
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('OAuth 시작 실패: $e')));
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF2A2A2A)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    backgroundColor: const Color(0xFF2A2A2A),
                  ),
                  icon: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Image.network(
                      'https://www.gstatic.com/firebasejs/ui/2.0.0/images/auth/google.svg',
                      width: 18,
                      height: 18,
                      errorBuilder: (c, e, s) => const Icon(Icons.account_circle, size: 18, color: Colors.white70),
                    ),
                  ),
                  label: const Text('Google로 회원가입'),
                ),
              ),
              const SizedBox(height: 4),
              const Text('Supabase 제공 양식에 맞춰 OAuth 버튼만 먼저 노출합니다.', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog();
  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  Map<String, dynamic> _profileMap = const {};
  String? _activeEmail;

  @override
  void initState() {
    super.initState();
    _reload();
    DataManager.instance.teachersNotifier.addListener(_reload);
  }

  @override
  void dispose() {
    DataManager.instance.teachersNotifier.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final map = await _ProfileStore.load();
    if (!mounted) return;
    setState(() {
      _profileMap = map['profiles'] as Map<String, dynamic>? ?? {};
      _activeEmail = map['activeEmail'] as String?;
    });
  }

  Teacher? _activeTeacher() {
    final email = _activeEmail ?? _safeClient()?.auth.currentUser?.email;
    if (email == null) return null;
    final list = DataManager.instance.teachersNotifier.value;
    try {
      return list.firstWhere((t) => t.email == email);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openAvatarPicker() async {
    final email = _activeEmail ?? _safeClient()?.auth.currentUser?.email;
    if (email == null) return;
    await showDialog(context: context, builder: (ctx) => _AvatarPickerDialog(email: email, initialMap: _profileMap));
    await _reload();
  }

  Future<void> _openSwitchProfile() async {
    await showDialog(context: context, builder: (ctx) => _SwitchProfileDialog(profileMap: _profileMap));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final client = _safeClient();
    final user = client?.auth.currentUser;
    final teacher = _activeTeacher();
    final email = _activeEmail ?? user?.email ?? '';
    final info = (_profileMap[email] as Map?) ?? {};
    final avatarPath = (info['avatar'] as String?) ?? '';
    final presetColor = (info['presetColor'] as String?) ?? '';
    final presetInitial = (info['presetInitial'] as String?) ?? '';
    final presetIcon = (info['presetIcon'] as String?) ?? '';
    final useIcon = (info['useIcon'] as bool?) ?? false;
    final isOwner = user?.email == email;
    final displayName = teacher?.name ?? (email.split('@').first);

    Widget avatarWidget() {
      final double size = 56;
      if (avatarPath.isNotEmpty && (avatarPath.startsWith('http') || File(avatarPath).existsSync())) {
        return GestureDetector(
          onTap: _openAvatarPicker,
          child: CircleAvatar(
            radius: size/2,
            backgroundImage: avatarPath.startsWith('http') ? NetworkImage(avatarPath) as ImageProvider : FileImage(File(avatarPath)),
          ),
        );
      }
      final googleUrl = (email == user?.email)
          ? (user?.userMetadata?['avatar_url'] ?? user?.userMetadata?['picture']) as String?
          : null;
      if (googleUrl != null && googleUrl.isNotEmpty) {
        return GestureDetector(
          onTap: _openAvatarPicker,
          child: CircleAvatar(radius: size/2, backgroundImage: NetworkImage(googleUrl)),
        );
      }
      final color = presetColor.isNotEmpty ? _parseColor(presetColor) : const Color(0xFF2A2A2A);
      final child = useIcon
          ? Icon(_iconFromKey(presetIcon), color: Colors.white)
          : Center(child: Text(presetInitial.isNotEmpty ? presetInitial : _initials(displayName), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)));
      return GestureDetector(
        onTap: _openAvatarPicker,
        child: CircleAvatar(radius: size/2, backgroundColor: color, child: child),
      );
    }

    return Dialog(
      backgroundColor: const Color(0xFF18181A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF2A2A2A))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children:[
                const Expanded(child: Text('계정', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800))),
                IconButton(onPressed: ()=>Navigator.of(context).pop(), icon: const Icon(Icons.close, color: Colors.white70))
              ]),
              const SizedBox(height: 18),
              Row(crossAxisAlignment: CrossAxisAlignment.center, children:[
                avatarWidget(),
                const SizedBox(width: 14),
                Expanded(
                  child: InkWell(
                    onTap: _openSwitchProfile,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
                      Row(children:[
                        Flexible(child: Text(displayName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(999)), child: Text(isOwner? '원장':'선생님', style: const TextStyle(color: Colors.white70, fontSize: 12)))
                      ]),
                      const SizedBox(height: 4),
                      Text(email, style: const TextStyle(color: Colors.white70))
                    ]),
                  ),
                )
              ]),
              const SizedBox(height: 18),
              // 추가 정보: 학원명, 연락처, PIN 설정
              Builder(builder: (ctx){
                final t = _activeTeacher();
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children:[
                  if (t!=null) Padding(padding: const EdgeInsets.only(bottom:18), child: Text('학원명: ${DataManager.instance.academySettings.name}', style: const TextStyle(color: Colors.white, fontSize: 16))),
                  if (t!=null && t.contact.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom:18), child: Text('연락처: ${t.contact}', style: const TextStyle(color: Colors.white, fontSize: 16))),
                  SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () async { await showDialog(context: context, builder: (ctx)=> _PinSetupDialog(email: email, initialMap: _profileMap)); await _reload(); },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF2A2A2A)),
                        backgroundColor: const Color(0xFF1F1F1F),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: const Text('PIN 설정', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]);
              }),
              const SizedBox(height: 8),
              // 하단 전체폭 로그아웃 버튼
              Row(children:[
                Expanded(child: ElevatedButton(
                  onPressed: () async {
                    try { await client?.auth.signOut(); if (mounted) Navigator.of(context).pop(); } catch (e) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('로그아웃 실패: $e'))); }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1976D2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text('로그아웃', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                ))
              ])
            ],
          ),
        ),
      ),
    );
  }
}

Color _parseColor(String hex) {
  var v = hex.replaceAll('#','');
  if (v.length == 6) v = 'FF$v';
  return Color(int.parse(v, radix: 16));
}

String _initials(String name) {
  final s = name.trim();
  if (s.isEmpty) return '?';
  final parts = s.split(RegExp(r'\s+'));
  if (parts.length == 1) return parts.first.characters.first.toUpperCase();
  return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
}

class _AccountTab extends StatelessWidget {
  final String userEmail;
  const _AccountTab({required this.userEmail});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const CircleAvatar(radius: 18, backgroundColor: Color(0xFF2A2A2A), child: Icon(Icons.person, color: Colors.white70, size: 18)),
            const SizedBox(width: 10),
            Expanded(child: Text(userEmail, style: const TextStyle(color: Colors.white, fontSize: 14))),
          ],
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: () async {
            try {
              final client = _safeClient();
              if (client == null) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Supabase 미초기화 상태입니다.')));
                return;
              }
              await client.auth.signOut();
              if (context.mounted) Navigator.of(context).pop();
            } catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('로그아웃 실패: $e')));
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('로그아웃', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}

class _ProfilesTab extends StatefulWidget {
  const _ProfilesTab();
  @override
  State<_ProfilesTab> createState() => _ProfilesTabState();
}

class _ProfilesTabState extends State<_ProfilesTab> {
  List<Teacher> _teachers = const [];
  Map<String, dynamic> _profileMap = const {};
  String? _activeEmail;

  @override
  void initState() {
    super.initState();
    _reload();
    DataManager.instance.teachersNotifier.addListener(_reload);
  }

  @override
  void dispose() {
    DataManager.instance.teachersNotifier.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _teachers = DataManager.instance.teachersNotifier.value;
    });
    final map = await _ProfileStore.load();
    setState(() {
      _profileMap = map['profiles'] as Map<String, dynamic>? ?? {};
      _activeEmail = map['activeEmail'] as String?;
    });
  }

  Future<void> _setActive(String email) async {
    final ok = await showDialog<bool>(context: context, barrierDismissible: true, builder: (ctx) => _PinDialog(email: email, profileMap: _profileMap));
    if (ok != true) return;
    await _ProfileStore.setActive(email, _profileMap);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('선생님 프로필', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
            TextButton(
              onPressed: () async {
                await showDialog(context: context, builder: (ctx) => _EditProfileDialog(onSaved: (email){ _reload(); }));
              },
              child: const Text('추가', style: TextStyle(color: Color(0xFF1976D2))),
            )
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: const Color(0xFF2A2A2A)), borderRadius: BorderRadius.circular(10)),
            child: ListView.builder(
              itemCount: _teachers.length,
              itemBuilder: (ctx, i) {
                final t = _teachers[i];
                final info = (_profileMap[t.email] as Map?) ?? {};
                final avatar = (info['avatar'] as String?) ?? '';
                final isActive = _activeEmail == t.email;
                final isOwner = _safeClient()?.auth.currentUser?.email == t.email;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFF2A2A2A),
                    backgroundImage: avatar.isNotEmpty && File(avatar).existsSync() ? FileImage(File(avatar)) : null,
                    child: avatar.isEmpty ? const Icon(Icons.person, color: Colors.white70) : null,
                  ),
                  title: Text(t.name, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(isOwner ? '원장' : '선생님', style: const TextStyle(color: Colors.white54)),
                  trailing: Wrap(spacing: 8, children: [
                    if (!isActive)
                      OutlinedButton(onPressed: ()=>_setActive(t.email), style: OutlinedButton.styleFrom(foregroundColor: Colors.white), child: const Text('전환')),
                    TextButton(onPressed: () async {
                      await showDialog(context: context, builder: (ctx)=> _EditProfileDialog(existing: t, onSaved: (_){ _reload(); }));
                    }, child: const Text('편집')),
                    TextButton(onPressed: () async {
                      await showDialog(context: context, builder: (ctx)=> _PinSetupDialog(email: t.email, initialMap: _profileMap));
                      await _reload();
                    }, child: const Text('PIN')),
                  ]),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileStore {
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/profiles.json');
    if (!await f.exists()) await f.writeAsString(jsonEncode({'profiles':{}, 'activeEmail': null}));
    return f;
  }
  static Future<Map<String, dynamic>> load() async {
    try {
      final f = await _file();
      final s = await f.readAsString();
      return (jsonDecode(s) as Map<String, dynamic>);
    } catch (_) { return {'profiles':{}, 'activeEmail': null}; }
  }
  static Future<void> save(Map<String, dynamic> map) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(map));
  }
  static Future<void> setActive(String email, Map<String, dynamic> map) async {
    final m = Map<String, dynamic>.from(map);
    m['activeEmail'] = email;
    await save(m);
  }
  static String sha256of(String s) => sha256.convert(utf8.encode(s)).toString();
}

class _PinDialog extends StatefulWidget {
  final String email; final Map profileMap;
  const _PinDialog({required this.email, required Map profileMap}) : profileMap = profileMap;
  @override State<_PinDialog> createState()=>_PinDialogState();
}
class _PinDialogState extends State<_PinDialog>{
  final c = TextEditingController(); String? err;
  @override Widget build(BuildContext context){
    final saved = (widget.profileMap[widget.email] as Map?)?['pinHash'] as String?;
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(saved==null? 'PIN 설정 필요':'PIN 입력', style: const TextStyle(color: Colors.white)),
      content: Column(mainAxisSize: MainAxisSize.min, children:[
        TextField(controller:c, maxLength:6, keyboardType: TextInputType.number, obscureText:true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(counterText:'', hintText:'6자리', hintStyle: TextStyle(color: Colors.white54))),
        if(err!=null) Padding(padding: const EdgeInsets.only(top:6), child: Text(err!, style: const TextStyle(color: Colors.redAccent)))
      ]),
      actions:[
        TextButton(onPressed: ()=>Navigator.pop(context,false), style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: const Color(0xFF23232A)), child: const Text('취소')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white), onPressed: () async{
          final v = c.text.trim(); if(v.length!=6){ setState(()=>err='6자리'); return; }
          if(saved==null){
            final map = await _ProfileStore.load();
            final p = Map<String,dynamic>.from((map['profiles'] as Map<String,dynamic>? ?? {}));
            final cur = Map<String,dynamic>.from((p[widget.email] as Map<String,dynamic>? ?? {}));
            cur['pinHash'] = _ProfileStore.sha256of(v);
            p[widget.email]=cur; await _ProfileStore.save({'profiles':p, 'activeEmail': map['activeEmail']});
            if(context.mounted) Navigator.pop(context,true);
          } else {
            final ok = saved == _ProfileStore.sha256of(v);
            if(context.mounted) Navigator.pop(context, ok);
          }
        }, child: const Text('확인'))
      ],
    );
  }
}

class _PinSetupDialog extends StatefulWidget{
  final String email; final Map initialMap; const _PinSetupDialog({required this.email, required this.initialMap});
  @override State<_PinSetupDialog> createState()=>_PinSetupDialogState();
}
class _PinSetupDialogState extends State<_PinSetupDialog>{
  final a=TextEditingController(); final b=TextEditingController(); String? err;
  @override Widget build(BuildContext context){
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('PIN 설정/변경', style: TextStyle(color: Colors.white)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children:[
        TextField(controller:a, maxLength:6, keyboardType: TextInputType.number, obscureText:true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(counterText:'', hintText:'새 PIN(6자리)', hintStyle: TextStyle(color: Colors.white54))),
        const SizedBox(height:8),
        TextField(controller:b, maxLength:6, keyboardType: TextInputType.number, obscureText:true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(counterText:'', hintText:'확인', hintStyle: TextStyle(color: Colors.white54))),
        if(err!=null) Padding(padding: const EdgeInsets.only(top:6), child: Text(err!, style: const TextStyle(color: Colors.redAccent)))
      ]),
      actions:[
        TextButton(onPressed: ()=>Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: const Color(0xFF23232A)), child: const Text('취소')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white), onPressed: () async{
          if(a.text!=b.text || a.text.length!=6){ setState(()=>err='6자리 동일하게 입력'); return; }
          final map = await _ProfileStore.load();
          final p = Map<String,dynamic>.from((map['profiles'] as Map<String,dynamic>? ?? {}));
          final cur = Map<String,dynamic>.from((p[widget.email] as Map<String,dynamic>? ?? {}));
          cur['pinHash'] = _ProfileStore.sha256of(a.text);
          p[widget.email]=cur; await _ProfileStore.save({'profiles':p, 'activeEmail': map['activeEmail']});
          if(context.mounted) Navigator.pop(context);
        }, child: const Text('저장'))
      ],
    );
  }
}

class _EditProfileDialog extends StatefulWidget{
  final Teacher? existing; final void Function(String email) onSaved; const _EditProfileDialog({this.existing, required this.onSaved});
  @override State<_EditProfileDialog> createState()=>_EditProfileDialogState();
}
class _EditProfileDialogState extends State<_EditProfileDialog>{
  late TextEditingController nameC; late TextEditingController contactC; late TextEditingController emailC; late TextEditingController descC; TeacherRole role=TeacherRole.all; String? avatarPath;
  @override void initState(){
    super.initState();
    final t=widget.existing;
    nameC=TextEditingController(text:t?.name??''); contactC=TextEditingController(text:t?.contact??''); emailC=TextEditingController(text:t?.email??''); descC=TextEditingController(text:t?.description??''); role=t?.role??TeacherRole.all;
  }
  @override void dispose(){ nameC.dispose(); contactC.dispose(); emailC.dispose(); descC.dispose(); super.dispose(); }
  @override Widget build(BuildContext context){
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(widget.existing==null?'프로필 추가':'프로필 편집', style: const TextStyle(color: Colors.white)),
      content: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, children:[
        Row(crossAxisAlignment: CrossAxisAlignment.center, children:[
          GestureDetector(
            onTap: () async {
              // 간단한 샘플(프리셋) 또는 파일 업로드는 _AvatarPickerDialog로 위임
              await showDialog(context: context, builder: (ctx)=> _AvatarPickerDialog(email: emailC.text.trim(), initialMap: const {}));
            },
            child: CircleAvatar(radius: 24, backgroundColor: const Color(0xFF2A2A2A), child: const Icon(Icons.person, color: Colors.white70)),
          ),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller:nameC, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText:'이름', hintStyle: TextStyle(color: Colors.white54)))),
          const SizedBox(width:12),
          Expanded(child: DropdownButtonFormField<TeacherRole>(value: role, items: TeacherRole.values.map((r)=>DropdownMenuItem(value:r, child: Text(getTeacherRoleLabel(r)))).toList(), onChanged:(v){ if(v!=null) setState(()=>role=v);}, dropdownColor: const Color(0xFF23232A), style: const TextStyle(color: Colors.white)))
        ]),
        const SizedBox(height:10),
        Row(children:[
          Expanded(child: TextField(controller:contactC, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText:'연락처', hintStyle: TextStyle(color: Colors.white54)))),
          const SizedBox(width:12),
          Expanded(child: TextField(controller:emailC, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText:'이메일', hintStyle: TextStyle(color: Colors.white54))))
        ]),
        const SizedBox(height:10),
        TextField(controller:descC, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText:'설명', hintStyle: TextStyle(color: Colors.white54))),
      ])),
      actions:[
        TextButton(onPressed: ()=>Navigator.pop(context), child: const Text('취소')),
        TextButton(onPressed: () async{
          final teacher = Teacher(name: nameC.text.trim(), role: role, contact: contactC.text.trim(), email: emailC.text.trim(), description: descC.text.trim());
          if(widget.existing==null){ DataManager.instance.addTeacher(teacher); }
          else{
            final idx = DataManager.instance.teachersNotifier.value.indexWhere((x)=>x.email==widget.existing!.email && x.name==widget.existing!.name);
            if(idx>=0) DataManager.instance.updateTeacher(idx, teacher);
          }
          widget.onSaved(teacher.email);
          if(context.mounted) Navigator.pop(context);
        }, child: const Text('저장'))
      ],
    );
  }
}

class _AvatarPickerDialog extends StatefulWidget{
  final String email; final Map initialMap; const _AvatarPickerDialog({required this.email, required this.initialMap});
  @override State<_AvatarPickerDialog> createState()=>_AvatarPickerDialogState();
}
class _AvatarPickerDialogState extends State<_AvatarPickerDialog>{
  String _color = '#1976D2';
  String? _filePath;
  String? _presetInitial; // 구글 스타일 레터 아바타
  final List<String> _initials = const ['A','B','C','D','E','F','G','H']; // 8개 레터 아바타(구글 스타일)
  final List<String> _iconKeys = const ['man','woman','boy','girl','person2','person3','person4','person5'];
  @override Widget build(BuildContext context){
    return AlertDialog(
      backgroundColor: const Color(0xFF18181A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF2A2A2A))),
      title: const Text('프로필 이미지', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 416,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children:[
          const Text('배경 색상', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for(final c in ['#1976D2','#6A1B9A','#2A2A2A','#0F467D','#009688','#8E44AD','#E67E22','#D32F2F','#388E3C','#455A64'])
              GestureDetector(onTap: ()=>setState(()=>_color=c), child: Container(width: 28, height: 28, decoration: BoxDecoration(color: _parseColor(c), border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(6)), child: _color==c? const Icon(Icons.check, size: 18, color: Colors.white): null)),
          ]),
          const SizedBox(height: 16),
          const Text('샘플 이미지', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 4,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for(int i=0;i<_iconKeys.length;i++)
                GestureDetector(
                  onTap: ()=> setState(()=> {_presetInitial = '', _filePath = null, }),
                  child: Container(
                    decoration: BoxDecoration(color: _parseColor(_color), borderRadius: BorderRadius.circular(12), border: Border.all(color: _iconKeys[i]==( (widget.initialMap['profiles'] as Map?)?[widget.email]?['presetIcon'] ?? '' ) ? const Color(0xFF1976D2) : const Color(0xFF2A2A2A), width: 2), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                    child: Center(child: Icon(_iconFromKey(_iconKeys[i]), color: Colors.white, size: 28)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: () async {
            final pick = await FilePicker.platform.pickFiles(type: FileType.image, withData: false);
            if(pick!=null && pick.files.isNotEmpty){ setState(()=> _filePath = pick.files.single.path); }
          }, icon: const Icon(Icons.upload, color: Colors.white70, size: 18), label: const Text('이미지 업로드', style: TextStyle(color: Colors.white))),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: () async {
            final user = _safeClient()?.auth.currentUser;
            final googleUrl = (user?.userMetadata?['avatar_url'] ?? user?.userMetadata?['picture']) as String?;
            if (googleUrl != null && googleUrl.isNotEmpty) {
              setState(()=> {_filePath = googleUrl, _presetInitial = null});
            } else {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('구글 프로필 이미지를 찾을 수 없습니다.')));
            }
          }, icon: const Icon(Icons.account_circle, color: Colors.white70, size: 18), label: const Text('구글 프로필 사용하기', style: TextStyle(color: Colors.white)))
        ]),
      ),
      actions: [
        TextButton(
          onPressed: ()=>Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: const Color(0xFF23232A)),
          child: const Text('취소'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white),
          onPressed: () async{
          final map = await _ProfileStore.load();
          final p = Map<String,dynamic>.from((map['profiles'] as Map<String,dynamic>? ?? {}));
          final cur = Map<String,dynamic>.from((p[widget.email] as Map<String,dynamic>? ?? {}));
            cur['presetColor'] = _color; cur['useIcon'] = true; cur['presetIcon'] = (_presetInitial==null || _presetInitial!.isNotEmpty) ? (cur['presetIcon'] ?? 'person2') : (cur['presetIcon'] ?? 'person2');
            if(_filePath!=null){ cur['avatar'] = _filePath; cur['useIcon'] = false; }
            if(_presetInitial!=null){ cur['presetInitial'] = _presetInitial; }
          p[widget.email]=cur; await _ProfileStore.save({'profiles':p, 'activeEmail': map['activeEmail']});
          if(context.mounted) Navigator.pop(context);
        }, child: const Text('저장'))
      ],
    );
  }
}

IconData _iconFromKey(String k){
  switch(k){
    case 'man': return Icons.man;
    case 'woman': return Icons.woman;
    case 'boy': return Icons.face_6;
    case 'girl': return Icons.face_3;
    case 'person2': return Icons.person_2;
    case 'person3': return Icons.person_3;
    case 'person4': return Icons.person_4;
    case 'person5': return Icons.person;
    default: return Icons.person;
  }
}

class _SwitchProfileDialog extends StatelessWidget{
  final Map profileMap; const _SwitchProfileDialog({required this.profileMap});
  @override Widget build(BuildContext context){
    final teachers = DataManager.instance.teachersNotifier.value;
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('프로필 전환', style: TextStyle(color: Colors.white)),
      content: SizedBox(width: 520, height: 360, child: ListView.builder(itemCount: teachers.length, itemBuilder: (ctx,i){
        final t=teachers[i]; final info = (profileMap[t.email] as Map?) ?? {}; final avatar = (info['avatar'] as String?) ?? '';
        return ListTile(
          leading: CircleAvatar(backgroundColor: const Color(0xFF2A2A2A), backgroundImage: avatar!=null && avatar.isNotEmpty && File(avatar).existsSync()? FileImage(File(avatar)) : null, child: avatar.isEmpty? const Icon(Icons.person, color: Colors.white70): null),
          title: Text(t.name, style: const TextStyle(color: Colors.white)),
          subtitle: Text(t.email, style: const TextStyle(color: Colors.white70)),
          onTap: () async {
            final ok = await showDialog<bool>(context: context, builder: (c)=> _PinDialog(email: t.email, profileMap: profileMap));
            if(ok==true && context.mounted){ await _ProfileStore.setActive(t.email, {'profiles': profileMap, 'activeEmail': t.email}); Navigator.pop(context); }
          },
        );
      })),
      actions:[TextButton(onPressed: ()=>Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: const Color(0xFF23232A)), child: const Text('닫기'))],
    );
  }
}