import 'package:flutter/material.dart';

import '../../services/think/think_models.dart';
import 'think_style.dart';

IconData thinkDepartmentIcon(ThinkDepartmentId d) => switch (d) {
      ThinkDepartmentId.education => Icons.school_outlined,
      ThinkDepartmentId.product => Icons.dashboard_customize_outlined,
      ThinkDepartmentId.engineering => Icons.code,
    };

/// 기억 범위 선택. 범위와 부서를 한 번에 고르므로 '부서인데 부서 없음' 상태가 생기지 않는다.
/// 레거시 기억은 사람이 고르기 전까지 '공통(레거시)'로 둔다(자동 재분류 없음).
/// [suggestedRole]은 제안만 보여 준다. '적용'을 누르기 전에는 범위를 바꾸지 않는다.
class ThinkMemoryScopePicker extends StatelessWidget {
  const ThinkMemoryScopePicker({
    super.key,
    required this.scope,
    required this.department,
    required this.onChanged,
    this.suggestedRole,
    this.showLegacy = false,
    this.enabled = true,
  });

  final ThinkMemoryScope scope;
  final ThinkDepartmentId? department;
  final void Function(ThinkMemoryScope scope, ThinkDepartmentId? department) onChanged;
  final ThinkRoleId? suggestedRole;
  final bool showLegacy;
  final bool enabled;

  bool _isDept(ThinkDepartmentId d) => scope == ThinkMemoryScope.department && department == d;

  @override
  Widget build(BuildContext context) {
    final suggested = suggestedRole?.department;
    final showSuggestion = enabled && suggested != null && !_isDept(suggested);
    return Semantics(
      container: true,
      label: '자료 범위',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('자료 범위', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (showLegacy || scope == ThinkMemoryScope.legacyUnscoped)
                ThinkToggleChip(
                  label: ThinkMemoryScope.legacyUnscoped.label,
                  icon: Icons.history,
                  selected: scope == ThinkMemoryScope.legacyUnscoped,
                  enabled: enabled,
                  tooltip: '역할 기능 전에 만든 기억입니다. 모든 역할이 봅니다.',
                  onChanged: (_) => onChanged(ThinkMemoryScope.legacyUnscoped, null),
                ),
              ThinkToggleChip(
                label: ThinkMemoryScope.common.label,
                icon: Icons.public,
                selected: scope == ThinkMemoryScope.common,
                enabled: enabled,
                tooltip: '모든 역할이 봅니다.',
                onChanged: (_) => onChanged(ThinkMemoryScope.common, null),
              ),
              for (final d in ThinkDepartmentId.values)
                ThinkToggleChip(
                  label: '${d.label} 부서',
                  icon: thinkDepartmentIcon(d),
                  selected: _isDept(d),
                  enabled: enabled,
                  tooltip: '${d.label} 역할과 총괄이 봅니다. 다른 역할은 참조하거나 대화에 연결할 때만 봅니다.',
                  onChanged: (_) => onChanged(ThinkMemoryScope.department, d),
                ),
            ],
          ),
          if (showSuggestion) ...[
            const SizedBox(height: 8),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                const Icon(Icons.lightbulb_outline, size: 16, color: kThinkHint),
                Text(
                  '지금 대화 역할(${suggestedRole!.label}) 기준 제안: ${suggested.label} 부서',
                  style: const TextStyle(color: kThinkHint, fontSize: 12),
                ),
                TextButton(
                  onPressed: () => onChanged(ThinkMemoryScope.department, suggested),
                  child: const Text('적용', style: TextStyle(color: kThinkAccent, fontSize: 12)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
