import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';

/// 상단 타이틀 줄 오른쪽에 두는 계정 아바타 버튼.
class StudentAccountButton extends StatefulWidget {
  const StudentAccountButton({super.key});

  @override
  State<StudentAccountButton> createState() => _StudentAccountButtonState();
}

class _StudentAccountButtonState extends State<StudentAccountButton> {
  late Future<StudentInfo?> _infoFuture;

  @override
  void initState() {
    super.initState();
    _infoFuture = StudentApi.instance.getInfo();
  }

  Future<void> _openAccount() async {
    StudentInfo? info;
    try {
      info = await _infoFuture;
    } catch (_) {
      // 계정 정보 조회가 실패해도 로그아웃은 제공한다.
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _StudentAccountDialog(info: info),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fallbackIconColor =
        isDark ? const Color(0xFFEAF2F2) : const Color(0xFF1F2933);

    return Tooltip(
      message: '계정',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _openAccount,
        child: FutureBuilder<StudentInfo?>(
          future: _infoFuture,
          builder: (context, snapshot) {
            final name = snapshot.data?.name.trim() ?? '';
            return CircleAvatar(
              radius: 20,
              backgroundColor:
                  YggGlassTokens.confirmActionColor.withValues(alpha: 0.14),
              foregroundColor: YggGlassTokens.confirmActionColor,
              child: name.isEmpty
                  ? Icon(Icons.person_rounded,
                      color: fallbackIconColor, size: 22)
                  : Text(
                      name.characters.first,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _StudentAccountDialog extends StatefulWidget {
  const _StudentAccountDialog({required this.info});

  final StudentInfo? info;

  @override
  State<_StudentAccountDialog> createState() => _StudentAccountDialogState();
}

class _StudentAccountDialogState extends State<_StudentAccountDialog> {
  bool _busy = false;

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await StudentApi.instance.signOut();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그아웃에 실패했어요.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final grade = info?.grade == null ? '' : ' · ${info!.grade}학년';
    return AlertDialog(
      title: const Text(
        '계정',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor:
                  YggGlassTokens.confirmActionColor.withValues(alpha: 0.14),
              foregroundColor: YggGlassTokens.confirmActionColor,
              child: Text(
                info?.name.trim().isNotEmpty == true
                    ? info!.name.trim().characters.first
                    : '?',
                style:
                    const TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              info?.name ?? '학생 계정',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            if (info != null) ...[
              const SizedBox(height: 5),
              Text(
                '${info.school}$grade',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _signOut,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(44),
              ),
              icon: _busy
                  ? const YggLoadingIndicator(size: 18)
                  : const Icon(Icons.logout_rounded),
              label: const Text(
                '로그아웃',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
