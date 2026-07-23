import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../services/student_api.dart';
import '../widgets/student_page_title.dart';

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
  String? _selectedGroupId;
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
        if (_selectedGroupId == null && groups.isNotEmpty) {
          _selectedGroupId = groups.first.groupId;
        }
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
    setState(() => _selectedGroupId = group.groupId);
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

  HomeworkGroup? _detailGroup(List<HomeworkGroup> groups) {
    for (final group in groups) {
      if (group.running) return group;
    }
    for (final group in groups) {
      if (group.groupId == _selectedGroupId) return group;
    }
    return groups.isEmpty ? null : groups.first;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final Widget body;
    if (groups == null) {
      body = Center(
        child: _error == null
            ? const YggLoadingIndicator(size: 32)
            : Text(_error!, textAlign: TextAlign.center),
      );
    } else if (groups.isEmpty) {
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: const [
            SizedBox(height: 160),
            Center(
              child: Text(
                '오늘은 등록된 과제가 없어요.',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final detail = _detailGroup(groups);
          final detailWidth =
              ((constraints.maxWidth - 68) / 3).clamp(280.0, 380.0);
          return Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _refresh,
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 8, 14, 112),
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
                          selected: detail?.groupId == groups[i].groupId,
                          onTap: () => _onGroupTap(groups[i]),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: detailWidth,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 20, 112),
                      child: _HomeworkDetailPanel(
                        group: detail!,
                        onSubmit: detail.phase == 2
                            ? () => _transition(
                                  detail,
                                  99,
                                  successMessage: '과제를 제출했어요!',
                                )
                            : null,
                        onReset: detail.phase == 4
                            ? () => _confirmPhase4(detail)
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
              if (!detail.isHomeworkOnly &&
                  (detail.phase == 1 || detail.phase == 2))
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Center(
                    child: _HomeworkActionFab(
                      busy: _busy,
                      running: detail.phase == 2,
                      onPressed: detail.phase == 2
                          ? _pauseAll
                          : () => _transition(
                                detail,
                                1,
                                successMessage: '${detail.title} 시작!',
                              ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    }

    return StudentCollapsingTitlePage(
      title: '홈',
      onRefresh: _refresh,
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
      ],
      bodyBuilder: (context, topInset, bottomInset) {
        return Padding(
          padding: EdgeInsets.only(top: topInset),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: body,
          ),
        );
      },
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.selected,
    required this.onTap,
  });

  final HomeworkGroup group;
  final bool selected;
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
    final emphasized = group.running || selected;

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
              color: emphasized
                  ? YggGlassTokens.confirmActionColor
                  : dlg.cardBorder,
              width: emphasized ? 1.6 : 0.8,
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
                      group.running
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
class _HomeworkDetailPanel extends StatelessWidget {
  const _HomeworkDetailPanel({
    required this.group,
    required this.onSubmit,
    required this.onReset,
  });

  final HomeworkGroup group;
  final VoidCallback? onSubmit;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return YggGroupedCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            group.title.isEmpty ? '(제목 없음)' : group.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (group.pageSummary.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              group.pageSummary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Expanded(
            child: group.children.isEmpty
                ? Center(
                    child: Text(
                      '세부 항목이 없어요.',
                      style: TextStyle(color: theme.hintColor),
                    ),
                  )
                : ListView.separated(
                    itemCount: group.children.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final child = group.children[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
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
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: child.memo.isNotEmpty
                            ? Text(
                                child.memo,
                                style: TextStyle(
                                  color: theme.hintColor,
                                  fontSize: 12.5,
                                ),
                              )
                            : null,
                        trailing: child.page.isNotEmpty
                            ? Text(
                                'p.${child.page}',
                                style: TextStyle(
                                  color: theme.hintColor,
                                  fontSize: 13,
                                ),
                              )
                            : null,
                      );
                    },
                  ),
          ),
          if (onSubmit != null || onReset != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onSubmit ?? onReset,
              icon: Icon(onSubmit != null
                  ? Icons.task_alt_rounded
                  : Icons.replay_rounded),
              label: Text(onSubmit != null ? '제출하기' : '대기로 되돌리기'),
            ),
          ],
        ],
      ),
    );
  }
}

class _HomeworkActionFab extends StatelessWidget {
  const _HomeworkActionFab({
    required this.busy,
    required this.running,
    required this.onPressed,
  });

  final bool busy;
  final bool running;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final background =
        running ? const Color(0xFF6B7280) : YggGlassTokens.confirmActionColor;
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(28),
      elevation: 8,
      shadowColor: Colors.black26,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: busy ? null : onPressed,
        child: SizedBox(
          height: 56,
          width: 144,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                const YggLoadingIndicator(size: 19)
              else
                Icon(
                  running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                ),
              const SizedBox(width: 8),
              Text(
                running ? '과제 중단' : '과제 수행',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
