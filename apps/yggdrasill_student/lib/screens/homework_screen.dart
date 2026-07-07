import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';

/// 과제 그룹 목록 + 상세(수행/제출) 화면.
///
/// phase 모델(M5와 동일):
///   1 대기 → 탭하면 수행 시작
///   2 수행 → 상세에서 일시정지/제출
///   3 제출 → 확인 대기 (조작 없음)
///   4 확인 → 탭하면 대기로 복귀
class HomeworkScreen extends StatefulWidget {
  const HomeworkScreen({super.key});

  @override
  State<HomeworkScreen> createState() => _HomeworkScreenState();
}

class _HomeworkScreenState extends State<HomeworkScreen> {
  List<HomeworkGroup>? _groups;
  String? _error;
  bool _busy = false;
  Timer? _ticker;
  Timer? _poller;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 수행 중 경과시간 갱신용 1초 틱 + 30초 주기 목록 폴링.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_groups?.any((g) => g.running) ?? false)) {
        setState(() {});
      }
    });
    _poller = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final groups = await StudentApi.instance.listHomeworkGroups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '과제를 불러오지 못했어요.\n$e');
    }
  }

  Future<void> _transition(HomeworkGroup group, int fromPhase,
      {String? successMessage}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await StudentApi.instance.groupTransition(
        groupId: group.groupId,
        fromPhase: fromPhase,
      );
      if (!mounted) return;
      if (result['ok'] == true) {
        if (successMessage != null) {
          TopGlassSnackBar.show(
            context,
            message: successMessage,
            icon: Icons.check_circle_outline_rounded,
          );
        }
      } else if (result['error'] == 'phase_mismatch') {
        TopGlassSnackBar.show(
          context,
          message: '선생님이 방금 과제 상태를 바꿨어요. 목록을 새로고침해요.',
          icon: Icons.sync_rounded,
        );
      } else {
        TopGlassSnackBar.show(
          context,
          message: '처리에 실패했어요. (${result['error']})',
          icon: Icons.error_outline_rounded,
        );
      }
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '통신에 실패했어요. 다시 시도해 주세요.',
          icon: Icons.wifi_off_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _pauseAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await StudentApi.instance.pauseAll();
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '과제를 일시정지했어요.',
          icon: Icons.pause_circle_outline_rounded,
        );
      }
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '일시정지에 실패했어요.',
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _addDescriptiveWriting() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await StudentApi.instance.createDescriptiveWriting();
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '서술형 쓰기 과제를 추가했어요.',
          icon: Icons.edit_note_rounded,
        );
      }
    } catch (_) {
      if (mounted) {
        TopGlassSnackBar.show(
          context,
          message: '과제 추가에 실패했어요.',
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  void _onGroupTap(HomeworkGroup group) {
    if (group.isHomeworkOnly) {
      TopGlassSnackBar.show(
        context,
        message: '숙제 검사를 먼저 받아야 해요.',
        icon: Icons.info_outline_rounded,
      );
      return;
    }
    switch (group.phase) {
      case 1:
        _transition(group, 1, successMessage: '${group.title} 시작!');
        break;
      case 2:
        _openDetail(group);
        break;
      case 3:
        TopGlassSnackBar.show(
          context,
          message: '제출된 과제예요. 선생님 확인을 기다려요.',
          icon: Icons.hourglass_top_rounded,
        );
        break;
      case 4:
        _confirmPhase4(group);
        break;
    }
  }

  Future<void> _confirmPhase4(HomeworkGroup group) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(group.title),
        content: const Text('확인이 끝난 과제예요. 대기 상태로 되돌릴까요?'),
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
            child: const Text('되돌리기'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await _transition(group, 4, successMessage: '대기로 되돌렸어요.');
    }
  }

  void _openDetail(HomeworkGroup group) {
    showUtilityGlassBottomSheet(
      context: context,
      title: group.title,
      icon: Icons.menu_book_rounded,
      preferredWidth: 560,
      child: _GroupDetailSheet(
        group: group,
        onPause: () {
          Navigator.of(context, rootNavigator: true).pop();
          _pauseAll();
        },
        onSubmit: () {
          Navigator.of(context, rootNavigator: true).pop();
          _transition(group, 99, successMessage: '과제를 제출했어요!');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          '오늘의 과제',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: '서술형 쓰기 추가',
            onPressed: _busy ? null : _addDescriptiveWriting,
            icon: const Icon(Icons.edit_note_rounded, size: 28),
          ),
          IconButton(
            tooltip: '새로고침',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: groups == null
            ? Center(
                child: _error == null
                    ? const YggLoadingIndicator(size: 32)
                    : Text(_error!, textAlign: TextAlign.center),
              )
            : groups.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 160),
                      Center(
                        child: Text(
                          '오늘은 등록된 과제가 없어요.',
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                    ],
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 440,
                      mainAxisExtent: 148,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                    ),
                    itemCount: groups.length,
                    itemBuilder: (context, i) => _GroupCard(
                      group: groups[i],
                      onTap: () => _onGroupTap(groups[i]),
                    ),
                  ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.onTap});

  final HomeworkGroup group;
  final VoidCallback onTap;

  static String _formatElapsed(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '$h:${'$m'.padLeft(2, '0')}:${'$s'.padLeft(2, '0')}';
    return '$m:${'$s'.padLeft(2, '0')}';
  }

  (Color, String) _phaseBadge(BuildContext context) {
    if (group.isHomeworkOnly) return (Colors.blueGrey, '숙제');
    if (group.pendingComplete) return (Colors.teal, '완료 예정');
    switch (group.phase) {
      case 2:
        return (YggGlassTokens.confirmActionColor, '수행 중');
      case 3:
        return (Colors.orangeAccent, '제출됨');
      case 4:
        return (Colors.lightBlueAccent, '확인');
      default:
        return (Colors.grey, '대기');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final (badgeColor, badgeLabel) = _phaseBadge(context);
    final groupColor =
        group.color != 0 ? Color(group.color | 0xFF000000) : dlg.border;
    final running = group.running;

    return Material(
      color: dlg.cardBg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: running ? YggGlassTokens.confirmActionColor : dlg.cardBorder,
              width: running ? 1.6 : 0.8,
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: groupColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      group.title.isEmpty ? '(제목 없음)' : group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: dlg.text,
                      ),
                    ),
                  ),
                  if (group.isTest)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.timer_outlined,
                          size: 18, color: Colors.orangeAccent),
                    ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badgeLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: badgeColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (group.pageSummary.isNotEmpty)
                Text(
                  group.pageSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: dlg.textSub),
                ),
              const Spacer(),
              Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 16, color: dlg.textSub),
                  const SizedBox(width: 4),
                  Text(
                    '${group.checkCount}/${group.totalCount}',
                    style: TextStyle(fontSize: 13, color: dlg.textSub),
                  ),
                  const Spacer(),
                  if (group.phase == 2) ...[
                    Icon(
                      running
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded,
                      size: 18,
                      color: YggGlassTokens.confirmActionColor,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      _formatElapsed(group.liveCycleElapsed()),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: YggGlassTokens.confirmActionColor,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// phase 2 상세 시트: 자식 과제 목록 + 일시정지/제출.
class _GroupDetailSheet extends StatelessWidget {
  const _GroupDetailSheet({
    required this.group,
    required this.onPause,
    required this.onSubmit,
  });

  final HomeworkGroup group;
  final VoidCallback onPause;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: group.children.isEmpty
                ? const Center(
                    child: Text(
                      '세부 항목이 없어요.',
                      style: TextStyle(color: Color(0xFF9FB3B3)),
                    ),
                  )
                : ListView.separated(
                    itemCount: group.children.length,
                    separatorBuilder: (_, __) => const Divider(
                      height: 1,
                      color: UtilityGlassDialogTokens.dividerColor,
                    ),
                    itemBuilder: (context, i) {
                      final child = group.children[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          child.phase >= 3
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: child.phase >= 3
                              ? YggGlassTokens.confirmActionColor
                              : const Color(0xFF9FB3B3),
                          size: 22,
                        ),
                        title: Text(
                          child.title,
                          style: const TextStyle(
                            color: Color(0xFFEAF2F2),
                            fontSize: 15,
                          ),
                        ),
                        subtitle: child.memo.isNotEmpty
                            ? Text(
                                child.memo,
                                style: const TextStyle(
                                  color: Color(0xFF9FB3B3),
                                  fontSize: 12.5,
                                ),
                              )
                            : null,
                        trailing: child.page.isNotEmpty
                            ? Text(
                                'p.${child.page}',
                                style: const TextStyle(
                                  color: Color(0xFF9FB3B3),
                                  fontSize: 13,
                                ),
                              )
                            : null,
                      );
                    },
                  ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPause,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    side: const BorderSide(color: Color(0x66FFFFFF)),
                    foregroundColor: const Color(0xFFEAF2F2),
                  ),
                  icon: const Icon(Icons.pause_rounded),
                  label: const Text('일시정지'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onSubmit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    backgroundColor: YggGlassTokens.confirmActionColor,
                  ),
                  icon: const Icon(Icons.task_alt_rounded),
                  label: const Text(
                    '제출하기',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
