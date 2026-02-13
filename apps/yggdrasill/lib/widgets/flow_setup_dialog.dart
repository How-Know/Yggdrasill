import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/student_flow.dart';
import '../services/student_flow_store.dart';
import '../widgets/dialog_tokens.dart';
import 'app_snackbar.dart';

Future<List<StudentFlow>> ensureEnabledFlowsForHomework(
  BuildContext context,
  String studentId,
) async {
  final flows = await StudentFlowStore.instance.loadForStudent(studentId);
  final enabled = flows.where((f) => f.enabled).toList();
  if (enabled.isNotEmpty) return enabled;

  final updated = await showDialog<List<StudentFlow>>(
    context: context,
    builder: (_) => FlowSetupDialog(
      studentId: studentId,
      initialFlows: flows,
    ),
  );
  if (updated == null) return const <StudentFlow>[];
  final refreshed =
      await StudentFlowStore.instance.loadForStudent(studentId, force: true);
  return refreshed.where((f) => f.enabled).toList();
}

class FlowSetupDialog extends StatefulWidget {
  final String studentId;
  final List<StudentFlow> initialFlows;

  const FlowSetupDialog({
    super.key,
    required this.studentId,
    required this.initialFlows,
  });

  @override
  State<FlowSetupDialog> createState() => _FlowSetupDialogState();
}

class _FlowSetupDialogState extends State<FlowSetupDialog> {
  final Uuid _uuid = Uuid();
  late List<StudentFlow> _flows;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _flows = widget.initialFlows.isNotEmpty
        ? List<StudentFlow>.from(widget.initialFlows)
        : _seedDefaultFlows();
  }

  List<StudentFlow> _seedDefaultFlows() {
    return [
      StudentFlow(id: _uuid.v4(), name: '현행', enabled: false, orderIndex: 0),
      StudentFlow(id: _uuid.v4(), name: '선행', enabled: false, orderIndex: 1),
    ];
  }

  String _nextFlowName() {
    const base = '플로우';
    final existing = _flows.map((f) => f.name).toSet();
    var idx = 1;
    var name = '$base $idx';
    while (existing.contains(name)) {
      idx += 1;
      name = '$base $idx';
    }
    return name;
  }

  void _addFlow() {
    setState(() {
      _flows.add(StudentFlow(
        id: _uuid.v4(),
        name: _nextFlowName(),
        enabled: false,
        orderIndex: _flows.length,
      ));
    });
  }

  void _toggleFlow(String id, bool enabled) {
    setState(() {
      final idx = _flows.indexWhere((f) => f.id == id);
      if (idx == -1) return;
      _flows[idx] = _flows[idx].copyWith(enabled: enabled);
    });
  }

  bool get _hasEnabled => _flows.any((f) => f.enabled);

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final ordered = _flows
          .asMap()
          .entries
          .map((e) => e.value.copyWith(orderIndex: e.key))
          .toList();
      await StudentFlowStore.instance.saveFlows(widget.studentId, ordered);
      if (!mounted) return;
      Navigator.of(context).pop(ordered);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, '플로우 저장 실패');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSaveButton = _hasEnabled || _saving;
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        '플로우 설정',
        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const YggDialogSectionHeader(
              icon: Icons.account_tree_outlined,
              title: '플로우 목록',
            ),
            Text(
              '플로우를 1개 이상 켜야 과제를 추가할 수 있어요.',
              style: TextStyle(color: kDlgTextSub.withOpacity(0.9)),
            ),
            const SizedBox(height: 12),
            if (_flows.isEmpty)
              const Text(
                '등록된 플로우가 없습니다.',
                style: TextStyle(color: kDlgTextSub),
              ),
            if (_flows.isNotEmpty)
              Column(
                children: [
                  for (final flow in _flows)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: kDlgPanelBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: kDlgBorder),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              flow.name,
                              style: const TextStyle(
                                color: kDlgText,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Switch(
                            value: flow.enabled,
                            onChanged: (v) => _toggleFlow(flow.id, v),
                            activeColor: kDlgAccent,
                            activeTrackColor: kDlgAccent.withOpacity(0.35),
                            inactiveThumbColor: kDlgTextSub,
                            inactiveTrackColor: kDlgBorder,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: _addFlow,
              icon: const Icon(Icons.add, size: 18, color: kDlgTextSub),
              label: const Text(
                '플로우 추가',
                style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: kDlgBorder),
                backgroundColor: kDlgPanelBg,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        if (showSaveButton)
          FilledButton(
            onPressed: _saving || !_hasEnabled ? null : _save,
            style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Text('저장'),
          ),
      ],
    );
  }
}
