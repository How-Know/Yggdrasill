import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';

/// 내 정보 + 오늘 출결 + 테마/로그아웃.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  StudentInfo? _info;
  TodayAttendance? _attendance;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        StudentApi.instance.getInfo(),
        StudentApi.instance.todayAttendance(),
      ]);
      if (!mounted) return;
      setState(() {
        _info = results[0] as StudentInfo?;
        _attendance = results[1] as TodayAttendance;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '정보를 불러오지 못했어요.\n$e');
    }
  }

  Future<void> _recordArrival() async {
    await _record(
      () => StudentApi.instance.recordArrival(),
      '등원이 기록됐어요. 오늘도 파이팅!',
    );
  }

  Future<void> _recordDeparture() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('하원'),
        content: const Text('하원으로 기록할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: YggGlassTokens.confirmActionColor,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('하원하기'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await _record(
        () => StudentApi.instance.recordDeparture(),
        '하원이 기록됐어요. 수고했어요!',
      );
    }
  }

  Future<void> _record(Future<void> Function() action, String message) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: message,
          icon: Icons.check_circle_outline_rounded,
        );
      }
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '기록에 실패했어요. 다시 시도해 주세요.',
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  static String _formatTime(DateTime? dt) {
    if (dt == null) return '-';
    return '${dt.hour}:${'${dt.minute}'.padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final info = _info;
    final att = _attendance;
    final arrived = att?.arrival != null;
    final departed = att?.departure != null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          '내 정보',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!, textAlign: TextAlign.center))
          : info == null
              ? const Center(child: YggLoadingIndicator(size: 32))
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 프로필 카드
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: dlg.cardBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: dlg.cardBorder),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 30,
                                backgroundColor: YggGlassTokens
                                    .confirmActionColor
                                    .withValues(alpha: 0.18),
                                child: Text(
                                  info.name.isNotEmpty ? info.name[0] : '?',
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    color: YggGlassTokens.confirmActionColor,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    info.name,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      color: dlg.text,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      if (info.school.isNotEmpty) info.school,
                                      if (info.grade != null)
                                        '${info.grade}학년',
                                    ].join(' · '),
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: dlg.textSub,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // 오늘 출결 카드
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: dlg.cardBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: dlg.cardBorder),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '오늘 출결',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: dlg.text,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(
                                    child: _AttendanceTile(
                                      label: '등원',
                                      value: _formatTime(att?.arrival),
                                      highlight: arrived,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _AttendanceTile(
                                      label: '하원',
                                      value: _formatTime(att?.departure),
                                      highlight: departed,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: (_busy || arrived)
                                          ? null
                                          : _recordArrival,
                                      style: FilledButton.styleFrom(
                                        minimumSize:
                                            const Size.fromHeight(48),
                                        backgroundColor:
                                            YggGlassTokens.confirmActionColor,
                                      ),
                                      icon: const Icon(Icons.login_rounded),
                                      label: const Text('등원'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: (_busy || !arrived || departed)
                                          ? null
                                          : _recordDeparture,
                                      style: OutlinedButton.styleFrom(
                                        minimumSize:
                                            const Size.fromHeight(48),
                                      ),
                                      icon: const Icon(Icons.logout_rounded),
                                      label: const Text('하원'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // 설정 카드
                        Container(
                          decoration: BoxDecoration(
                            color: dlg.cardBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: dlg.cardBorder),
                          ),
                          child: Column(
                            children: [
                              ValueListenableBuilder<ThemeMode>(
                                valueListenable: AppThemeController.mode,
                                builder: (context, mode, _) => SwitchListTile(
                                  title: Text(
                                    '다크 모드',
                                    style: TextStyle(color: dlg.text),
                                  ),
                                  activeTrackColor:
                                      YggGlassTokens.confirmActionColor,
                                  value: mode == ThemeMode.dark,
                                  onChanged: (v) => AppThemeController.setMode(
                                    v ? ThemeMode.dark : ThemeMode.light,
                                  ),
                                ),
                              ),
                              Divider(height: 1, color: dlg.divider),
                              ListTile(
                                leading: const Icon(
                                  Icons.logout_rounded,
                                  color: Colors.redAccent,
                                ),
                                title: const Text(
                                  '로그아웃',
                                  style: TextStyle(color: Colors.redAccent),
                                ),
                                onTap: () => StudentApi.instance.signOut(),
                              ),
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

class _AttendanceTile extends StatelessWidget {
  const _AttendanceTile({
    required this.label,
    required this.value,
    required this.highlight,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: highlight
            ? YggGlassTokens.confirmActionColor.withValues(alpha: 0.12)
            : dlg.panelBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 13, color: dlg.textSub),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: highlight
                  ? YggGlassTokens.confirmActionColor
                  : dlg.text,
            ),
          ),
        ],
      ),
    );
  }
}
