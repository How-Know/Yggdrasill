import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../screens/settings/settings_screen.dart';
import 'dart:io' show Platform, HttpServer, File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
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
                                // 로그인 되어 있으면 간단한 프로필/로그아웃 선택
                                await showDialog(
                                  context: context,
                                  barrierDismissible: true,
                                  builder: (ctx) => const _AccountDialog(),
                                );
                              }
                            },
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.grey.shade700,
                              child: const Icon(Icons.person, color: Colors.white70, size: 20),
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
        constraints: const BoxConstraints(maxWidth: 520),
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

class _AccountDialog extends StatelessWidget {
  const _AccountDialog();
  @override
  Widget build(BuildContext context) {
    final client = _safeClient();
    final user = client?.auth.currentUser;
    return Dialog(
      backgroundColor: const Color(0xFF18181A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF2A2A2A))),
      child: DefaultTabController(
        length: 2,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
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
                const SizedBox(height:8),
                const TabBar(indicatorColor: Color(0xFF1976D2), labelColor: Colors.white, unselectedLabelColor: Colors.white54, tabs:[Tab(text:'내 계정'), Tab(text:'프로필')]),
                SizedBox(
                  height: 420,
                  child: TabBarView(children:[
                    _AccountTab(userEmail: user?.email ?? ''),
                    const _ProfilesTab(),
                  ]),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
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
      content: TextField(controller:c, maxLength:6, keyboardType: TextInputType.number, obscureText:true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(counterText:'', hintText:'6자리', hintStyle: TextStyle(color: Colors.white54))),
      actions:[
        TextButton(onPressed: ()=>Navigator.pop(context,false), child: const Text('취소')),
        TextButton(onPressed: () async{
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
      content: Column(mainAxisSize: MainAxisSize.min, children:[
        TextField(controller:a, maxLength:6, keyboardType: TextInputType.number, obscureText:true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(counterText:'', hintText:'새 PIN(6자리)', hintStyle: TextStyle(color: Colors.white54))),
        const SizedBox(height:8),
        TextField(controller:b, maxLength:6, keyboardType: TextInputType.number, obscureText:true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(counterText:'', hintText:'확인', hintStyle: TextStyle(color: Colors.white54))),
        if(err!=null) Padding(padding: const EdgeInsets.only(top:6), child: Text(err!, style: const TextStyle(color: Colors.redAccent)))
      ]),
      actions:[
        TextButton(onPressed: ()=>Navigator.pop(context), child: const Text('취소')),
        TextButton(onPressed: () async{
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
  late TextEditingController nameC; late TextEditingController contactC; late TextEditingController emailC; late TextEditingController descC; TeacherRole role=TeacherRole.all;
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
        Row(children:[
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