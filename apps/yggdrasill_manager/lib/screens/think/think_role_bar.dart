import 'package:flutter/material.dart';

import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_avatars.dart';
import 'think_memory_scope_picker.dart';
import 'think_style.dart';

/// 대화 머리의 역할 선택(컨트롤러 연결). 역할 기능이 준비되지 않으면 그리지 않는다.
class ThinkRoleBar extends StatelessWidget {
  const ThinkRoleBar({super.key});

  ThinkController get _c => ThinkController.instance;

  Future<void> _run(BuildContext context, Future<String?> Function() action) async {
    final error = await action();
    if (error != null && context.mounted) showThinkSnack(context, error, error: true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_c.rolesReady) return const SizedBox.shrink();
    return ThinkRoleBarView(
      role: _c.conversationRole,
      extraRefs: _c.extraRefDepartments,
      answering: _c.streamingHere,
      lockReason: _c.roleLockReason,
      newConversation: _c.selectedId == null,
      onRole: (r) => _run(context, () => _c.setConversationRole(r)),
      onToggleRef: (d) => _run(context, () => _c.toggleExtraRefDepartment(d)),
    );
  }
}

/// 역할 선택 화면 조각(데이터만 받는다. Preview에서도 쓴다).
/// 좁으면(720px 미만) 역할 칩을 아바타만 보이게 줄이고 이름은 툴팁·낭독기로 알린다.
class ThinkRoleBarView extends StatelessWidget {
  const ThinkRoleBarView({
    super.key,
    required this.role,
    required this.extraRefs,
    required this.onRole,
    required this.onToggleRef,
    this.answering = false,
    this.lockReason,
    this.newConversation = false,
  });

  final ThinkRoleId role;
  final List<ThinkDepartmentId> extraRefs;
  final ValueChanged<ThinkRoleId> onRole;
  final ValueChanged<ThinkDepartmentId> onToggleRef;
  final bool answering;

  /// null이면 바꿀 수 있다. 값이 있으면 칩을 잠그고 이유를 보여 준다.
  final String? lockReason;
  final bool newConversation;

  @override
  Widget build(BuildContext context) {
    final enabled = lockReason == null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final refOptions = ThinkDepartmentId.values.where((d) => d != role.department).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ThinkRoleAvatar(role: role, size: 28, active: answering),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Think(${role.label})${answering ? ' 답하는 중' : ''}',
                    style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 4),
                for (final r in ThinkRoleId.values)
                  _RoleChip(
                    role: r,
                    selected: role == r,
                    enabled: enabled,
                    compact: compact,
                    onTap: () => onRole(r),
                  ),
              ],
            ),
            if (role != ThinkRoleId.lead) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Tooltip(
                    message: '켜면 그 부서 기억도 이 대화에서 씁니다.',
                    child: Text('다른 부서 참조', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  for (final d in refOptions)
                    ThinkToggleChip(
                      label: d.label,
                      icon: thinkDepartmentIcon(d),
                      selected: extraRefs.contains(d),
                      enabled: enabled,
                      tooltip: '${d.label} 부서 기억 참조',
                      onChanged: (_) => onToggleRef(d),
                    ),
                ],
              ),
            ],
            if (lockReason != null || newConversation) ...[
              const SizedBox(height: 4),
              Text(
                lockReason ?? '첫 메시지를 보내면 이 역할로 대화를 시작합니다.',
                style: const TextStyle(color: kThinkHint, fontSize: 12),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({
    required this.role,
    required this.selected,
    required this.enabled,
    required this.compact,
    required this.onTap,
  });

  final ThinkRoleId role;
  final bool selected;
  final bool enabled;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = thinkRoleColor(role);
    final chip = Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      label: '${role.label} 역할',
      excludeSemantics: true,
      child: Material(
        color: selected ? color.withValues(alpha: 0.16) : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: selected ? color.withValues(alpha: 0.6) : kThinkBorder)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled && !selected ? onTap : null,
          focusColor: kThinkAccent.withValues(alpha: 0.24),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(opacity: enabled || selected ? 1 : 0.5, child: ThinkRoleAvatar(role: role, size: 24)),
                if (!compact) ...[
                  const SizedBox(width: 8),
                  Text(
                    role.label,
                    style: TextStyle(
                      color: enabled || selected ? kThinkText : kThinkHint,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return compact ? Tooltip(message: '${role.label} 역할', child: chip) : chip;
  }
}
