import 'package:flutter/material.dart';

import '../../../../services/think/think_models.dart';
import '../../../think/think_avatars.dart';
import '../../../think/think_style.dart';
import '../../../think/think_tree_panel.dart';

/// Think 부서 캐릭터·부서 트리 머리 Preview (목업 데이터만, Supabase 없음).
/// 캐릭터는 상태마다 움직임이 다르다. 모션 감소 설정이면 첫 장면에서 멈춘다.
class ThinkDepartmentsPreviewScreen extends StatefulWidget {
  const ThinkDepartmentsPreviewScreen({super.key});

  @override
  State<ThinkDepartmentsPreviewScreen> createState() => _ThinkDepartmentsPreviewScreenState();
}

class _ThinkDepartmentsPreviewScreenState extends State<ThinkDepartmentsPreviewScreen> {
  final Map<ThinkRoleId, ThinkDepartmentActivity> _states = {
    ThinkRoleId.lead: const ThinkDepartmentActivity(ThinkActivity.answering),
    ThinkRoleId.education: const ThinkDepartmentActivity(ThinkActivity.consulting, consultWith: ThinkRoleId.engineering),
    ThinkRoleId.product: const ThinkDepartmentActivity(ThinkActivity.waiting, count: 2),
    ThinkRoleId.engineering: const ThinkDepartmentActivity(ThinkActivity.consulting, consultWith: ThinkRoleId.education),
  };
  final Set<ThinkRoleId> _collapsed = {ThinkRoleId.lead};

  static const Map<ThinkRoleId, List<String>> _mockRows = {
    ThinkRoleId.lead: ['운영 방향'],
    ThinkRoleId.education: ['미분류 · 2학기 진도 조정', '수업 설계', '  숙제 단위 정하기'],
    ThinkRoleId.product: ['미분류 · 오답 유형 묶기', '문제 은행', '  난이도 표기 기준'],
    ThinkRoleId.engineering: ['학습앱', '  채점 화면 개선'],
  };

  ThinkDepartmentActivity _example(ThinkActivity a, ThinkRoleId r) => switch (a) {
        ThinkActivity.consulting => ThinkDepartmentActivity(a,
            consultWith: r == ThinkRoleId.engineering ? ThinkRoleId.education : ThinkRoleId.engineering),
        ThinkActivity.waiting => ThinkDepartmentActivity(a, count: 2),
        ThinkActivity.coding => ThinkDepartmentActivity(a, count: 1),
        _ => ThinkDepartmentActivity(a),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kThinkBg,
      appBar: AppBar(
        backgroundColor: kThinkBg,
        foregroundColor: kThinkText,
        title: const Text('Think 부서 Preview'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('부서 캐릭터 × 상태', style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Table(
            defaultColumnWidth: const FixedColumnWidth(112),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(children: [
                const SizedBox(),
                for (final a in ThinkActivity.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(a.label, textAlign: TextAlign.center, style: const TextStyle(color: kThinkSub, fontSize: 12)),
                  ),
              ]),
              for (final r in ThinkRoleId.values)
                TableRow(children: [
                  Text(r.label, style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700)),
                  for (final a in ThinkActivity.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Center(
                        child: ThinkRoleAvatar(role: r, size: 56, activity: a, semanticsLabel: '${r.label} ${a.label}'),
                      ),
                    ),
                ]),
            ],
          ),
          const SizedBox(height: 32),
          const Text('부서 트리 (왼쪽 목록)', style: TextStyle(color: kThinkText, fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text(
            '상태 칩을 눌러 부서마다 상태를 바꿔 보세요. 부서 머리를 누르면 접힙니다.',
            style: TextStyle(color: kThinkHint, fontSize: 12),
          ),
          const SizedBox(height: 12),
          for (final r in ThinkRoleId.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(width: 72, child: Text(r.label, style: const TextStyle(color: kThinkSub, fontSize: 12))),
                  for (final a in ThinkActivity.values)
                    ThinkToggleChip(
                      label: a.label,
                      icon: Icons.circle_outlined,
                      selected: _states[r]?.activity == a,
                      onChanged: (_) => setState(() => _states[r] = _example(a, r)),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 300,
              child: ThinkPanel(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final r in ThinkRoleId.values) ...[
                      ThinkDepartmentHeader(
                        role: r,
                        activity: _states[r]!,
                        summary: r == ThinkRoleId.lead ? '폴더 1' : '폴더 1 · 미분류 1',
                        collapsed: _collapsed.contains(r),
                        onToggle: () => setState(() => _collapsed.contains(r) ? _collapsed.remove(r) : _collapsed.add(r)),
                        onNewFolder: () {},
                        resolve: (_) => null,
                        onDrop: (_) {},
                      ),
                      if (!_collapsed.contains(r))
                        for (final row in _mockRows[r]!) _MockRow(text: row),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MockRow extends StatelessWidget {
  const _MockRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final nested = text.startsWith('  ');
    final unfiled = text.startsWith('미분류');
    final folder = !nested && !unfiled;
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          SizedBox(width: nested ? 56 : 32),
          Icon(
            folder ? Icons.folder_open_outlined : Icons.chat_bubble_outline,
            size: 16,
            color: folder ? kThinkSub : kThinkHint,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kThinkText, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
