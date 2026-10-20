import 'package:flutter/material.dart';

import '../../../../services/think/think_models.dart';
import '../../../think/think_avatars.dart';
import '../../../think/think_materials_panel.dart';
import '../../../think/think_memory_scope_picker.dart';
import '../../../think/think_role_bar.dart';
import '../../../think/think_style.dart';

/// Think 역할 머리·아바타·자료 패널·기억 범위 선택 Preview (목업 데이터만, Supabase 없음).
/// 폭 버튼으로 좁은 화면(아바타만 보이는 역할 칩)을 확인한다. '답하는 중'은 캐릭터가 움직이고, 모션 감소 설정이면 멈춘다.
class ThinkRolesPreviewScreen extends StatefulWidget {
  const ThinkRolesPreviewScreen({super.key});

  @override
  State<ThinkRolesPreviewScreen> createState() => _ThinkRolesPreviewScreenState();
}

class _ThinkRolesPreviewScreenState extends State<ThinkRolesPreviewScreen> {
  ThinkRoleId _role = ThinkRoleId.education;
  final List<ThinkDepartmentId> _refs = [ThinkDepartmentId.product];
  bool _answering = false;
  bool _locked = false;
  double _width = 900;
  int _answer = 0;
  ThinkMemoryScope _scope = ThinkMemoryScope.common;
  ThinkDepartmentId? _dept;

  static const _snapshot = ThinkMessageContextSnapshot(
    messageId: 'm1',
    thinkRoleId: ThinkRoleId.education,
    roleProfileVersion: 'think-role-2026-10-10',
    materials: [
      ThinkMessageMaterialRef(kind: 'memory', id: 'a', title: '반복 사고를 먼저 훈련한다'),
      ThinkMessageMaterialRef(kind: 'memory', id: 'b', title: '숙제는 수업 단위로 끊는다'),
      ThinkMessageMaterialRef(kind: 'document', id: 'd', title: '2학기 진도 운영안', truncated: true),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kThinkBg,
      appBar: AppBar(
        backgroundColor: kThinkBg,
        foregroundColor: kThinkText,
        title: const Text('Think 역할 UI Preview'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              for (final r in ThinkRoleId.values)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ThinkRoleAvatar(role: r, size: 56, semanticsLabel: '${r.label} 역할 아바타'),
                    const SizedBox(height: 8),
                    Text(r.label, style: const TextStyle(color: kThinkSub, fontSize: 13)),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ThinkToggleChip(label: '답하는 중', icon: Icons.graphic_eq, selected: _answering, onChanged: (v) => setState(() => _answering = v)),
              ThinkToggleChip(label: '잠김(스트리밍)', icon: Icons.lock_outline, selected: _locked, onChanged: (v) => setState(() => _locked = v)),
              for (final w in [1200.0, 900.0, 560.0])
                ThinkToggleChip(
                  label: '폭 ${w.toInt()}',
                  icon: Icons.width_normal_outlined,
                  selected: _width == w,
                  onChanged: (_) => setState(() => _width = w),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: _width,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(border: Border.all(color: kThinkBorder), borderRadius: BorderRadius.circular(12)),
              child: ThinkRoleBarView(
                role: _role,
                extraRefs: _refs,
                answering: _answering,
                lockReason: _locked ? '답변이 끝난 뒤 바꿀 수 있습니다.' : null,
                onRole: (r) => setState(() {
                  _role = r;
                  _refs.removeWhere((d) => d == r.department);
                  if (r == ThinkRoleId.lead) _refs.clear();
                }),
                onToggleRef: (d) => setState(() => _refs.contains(d) ? _refs.remove(d) : _refs.add(d)),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            children: [
              for (final (i, label) in const [(0, '선택 없음'), (1, '스냅샷 있는 답변'), (2, '기록 없는 예전 답변')])
                ThinkToggleChip(
                  label: label,
                  icon: Icons.library_books_outlined,
                  selected: _answer == i,
                  onChanged: (_) => setState(() => _answer = i),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 320,
            child: ThinkPanel(
              padding: const EdgeInsets.all(16),
              child: ThinkMaterialsPanelView(
                hasSelection: _answer != 0,
                snapshot: _answer == 1 ? _snapshot : null,
                recordMissing: _answer == 2,
                lockReason: _locked ? '답변이 끝난 뒤 바꿀 수 있습니다.' : null,
                linkedMemories: const [ThinkLinkedItem(id: 'p', title: '교재 선택 기준', note: '문제 풀이 부서')],
                linkedDocuments: const [ThinkLinkedItem(id: 'd', title: '2학기 진도 운영안', note: '진도 회의')],
                onLinkMemory: () {},
                onLinkDocument: () {},
                onUnlinkMemory: (_) {},
                onUnlinkDocument: (_) {},
              ),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 640,
            child: ThinkMemoryScopePicker(
              scope: _scope,
              department: _dept,
              showLegacy: true,
              suggestedRole: _role,
              onChanged: (s, d) => setState(() {
                _scope = s;
                _dept = d;
              }),
            ),
          ),
        ],
      ),
    );
  }
}
