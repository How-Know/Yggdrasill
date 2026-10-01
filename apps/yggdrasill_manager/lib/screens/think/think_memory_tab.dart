import 'package:flutter/material.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_spec_export_dialog.dart';
import 'think_style.dart';

Color _kindColor(ThinkMemoryKind k) => switch (k) {
      ThinkMemoryKind.identity => kThinkAccent,
      ThinkMemoryKind.principle => kThinkBlue,
      ThinkMemoryKind.decision => kThinkLink,
      ThinkMemoryKind.note => kThinkSub,
    };

class ThinkMemoryTab extends StatefulWidget {
  const ThinkMemoryTab({super.key});

  @override
  State<ThinkMemoryTab> createState() => _ThinkMemoryTabState();
}

class _ThinkMemoryTabState extends State<ThinkMemoryTab> {
  ThinkMemoryKind? _kind;
  final Set<ThinkMemoryStatus> _statuses = {ThinkMemoryStatus.active, ThinkMemoryStatus.draft};
  String _search = '';
  bool _creating = false;

  ThinkController get _c => ThinkController.instance;

  List<ThinkMemory> get _filtered {
    final q = _search.trim().toLowerCase();
    return _c.memories.where((m) {
      if (_kind != null && m.kind != _kind) return false;
      if (!_statuses.contains(m.status)) return false;
      if (q.isEmpty) return true;
      return m.title.toLowerCase().contains(q) ||
          m.content.toLowerCase().contains(q) ||
          m.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: _c, builder: (context, _) => _build());
  }

  Widget _build() {
    final selected = _creating ? null : _c.memoryById(_c.selectedMemoryId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 420, child: _listPanel()),
        const SizedBox(width: 16),
        Expanded(
          child: ThinkPanel(
            child: _creating || selected != null
                ? _MemoryEditor(
                    key: ValueKey(_creating ? 'new' : selected!.id),
                    memory: selected,
                    initialKind: _kind ?? ThinkMemoryKind.note,
                    onSaved: (m) {
                      setState(() => _creating = false);
                      _c.selectMemory(m.id);
                    },
                    onCancelNew: () => setState(() => _creating = false),
                  )
                : const Center(
                    child: Text('왼쪽에서 기억을 고르거나 새로 만드세요.', style: TextStyle(color: kThinkHint)),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _listPanel() {
    final items = _filtered;
    return ThinkPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
            child: Row(
              children: [
                const Text('기억', style: TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Text('${items.length}개', style: const TextStyle(color: kThinkHint, fontSize: 12)),
                const Spacer(),
                IconButton(
                  tooltip: '새로고침',
                  iconSize: 18,
                  color: kThinkSub,
                  onPressed: _c.refreshMemories,
                  icon: const Icon(Icons.refresh),
                ),
                const SizedBox(width: 4),
                OutlinedButton.icon(
                  onPressed: _c.forbidden
                      ? null
                      : () {
                          setState(() => _creating = true);
                          _c.selectMemory(null);
                        },
                  style: thinkOutlineButton(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('새 기억'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              style: const TextStyle(color: kThinkText, fontSize: 13),
              decoration: thinkInputDecoration(
                hint: '제목·내용·태그 검색',
                dense: true,
                prefixIcon: const Icon(Icons.search, size: 18, color: kThinkHint),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ThinkToggleChip(
                  label: '전체',
                  icon: Icons.all_inclusive,
                  selected: _kind == null,
                  onChanged: (_) => setState(() => _kind = null),
                ),
                for (final k in ThinkMemoryKind.values)
                  ThinkToggleChip(
                    label: k.label,
                    icon: switch (k) {
                      ThinkMemoryKind.identity => Icons.favorite_border,
                      ThinkMemoryKind.principle => Icons.rule,
                      ThinkMemoryKind.decision => Icons.fact_check_outlined,
                      ThinkMemoryKind.note => Icons.sticky_note_2_outlined,
                    },
                    selected: _kind == k,
                    onChanged: (_) => setState(() => _kind = k),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in ThinkMemoryStatus.values)
                  ThinkToggleChip(
                    label: s.label,
                    icon: _statuses.contains(s) ? Icons.check_box_outlined : Icons.check_box_outline_blank,
                    selected: _statuses.contains(s),
                    onChanged: (on) => setState(() => on ? _statuses.add(s) : _statuses.remove(s)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Divider(color: kThinkBorder, height: 1),
          Expanded(
            child: _c.memoriesLoading && _c.memories.isEmpty
                ? const Center(child: CircularProgressIndicator(color: kThinkAccent))
                : _c.memoriesError != null && _c.memories.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_c.memoriesError!, style: const TextStyle(color: kThinkSub, fontSize: 12)),
                      )
                    : items.isEmpty
                        ? const Center(child: Text('조건에 맞는 기억이 없습니다.', style: TextStyle(color: kThinkHint)))
                        : ListView.builder(
                            padding: const EdgeInsets.all(8),
                            itemCount: items.length,
                            itemBuilder: (_, i) => _memoryTile(items[i]),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _memoryTile(ThinkMemory m) {
    final selected = !_creating && _c.selectedMemoryId == m.id;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () {
            setState(() => _creating = false);
            _c.selectMemory(m.id);
          },
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ThinkBadge(m.kind.label, color: _kindColor(m.kind)),
                    if (m.status != ThinkMemoryStatus.active) ...[
                      const SizedBox(width: 4),
                      ThinkBadge(m.status.label, color: m.status == ThinkMemoryStatus.draft ? kThinkBlue : kThinkHint),
                    ],
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        m.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: kThinkText, fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  m.content.replaceAll(RegExp(r'\s+'), ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kThinkSub, fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      'v${m.version} · ${formatRelative(m.updatedAt)}',
                      style: const TextStyle(color: kThinkHint, fontSize: 12),
                    ),
                    if (m.specPath != null) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.description_outlined, size: 12, color: kThinkHint),
                      const SizedBox(width: 4),
                      const Text('스펙', style: TextStyle(color: kThinkHint, fontSize: 12)),
                    ],
                    if (m.tags.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          m.tags.map((t) => '#$t').join(' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: kThinkHint, fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemoryEditor extends StatefulWidget {
  const _MemoryEditor({
    super.key,
    required this.memory,
    required this.initialKind,
    required this.onSaved,
    required this.onCancelNew,
  });

  final ThinkMemory? memory;
  final ThinkMemoryKind initialKind;
  final ValueChanged<ThinkMemory> onSaved;
  final VoidCallback onCancelNew;

  @override
  State<_MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<_MemoryEditor> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  final _context = TextEditingController();
  final _reason = TextEditingController();
  final _alternatives = TextEditingController();
  final _tags = TextEditingController();
  final _sortOrder = TextEditingController();
  late ThinkMemoryKind _kind;
  late ThinkMemoryStatus _status;
  int _loadedVersion = 0;
  bool _dirty = false;
  bool _saving = false;
  bool _filling = false;

  ThinkController get _c => ThinkController.instance;
  List<TextEditingController> get _fields => [_title, _content, _context, _reason, _alternatives, _tags, _sortOrder];

  @override
  void initState() {
    super.initState();
    _fill(widget.memory);
    for (final f in _fields) {
      f.addListener(_markDirty);
    }
  }

  @override
  void didUpdateWidget(covariant _MemoryEditor old) {
    super.didUpdateWidget(old);
    final m = widget.memory;
    if (m != null && m.version != _loadedVersion && !_dirty && !_saving) _fill(m);
  }

  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (_filling || _dirty) return;
    setState(() => _dirty = true);
  }

  void _fill(ThinkMemory? m) {
    final d = m == null
        ? ThinkMemoryDraft(kind: widget.initialKind, status: ThinkMemoryStatus.active)
        : ThinkMemoryDraft.fromMemory(m);
    _filling = true;
    _title.text = d.title;
    _content.text = d.content;
    _context.text = d.decisionContext;
    _reason.text = d.decisionReason;
    _alternatives.text = d.alternatives.join('\n');
    _tags.text = d.tags.join(', ');
    _sortOrder.text = '${d.sortOrder}';
    _filling = false;
    _kind = d.kind;
    _status = d.status;
    _loadedVersion = m?.version ?? 0;
    _dirty = false;
  }

  ThinkMemoryDraft _draft() => ThinkMemoryDraft(
        kind: _kind,
        status: _status,
        title: _title.text,
        content: _content.text,
        decisionContext: _context.text,
        decisionReason: _reason.text,
        alternatives: _alternatives.text.split('\n'),
        tags: _tags.text.split(RegExp(r'[,，]')),
        sortOrder: int.tryParse(_sortOrder.text.trim()) ?? 0,
        sourceConversationId: widget.memory?.sourceConversationId,
        supersedesId: widget.memory?.supersedesId,
      );

  Future<void> _run(Future<ThinkMemory?> Function() action, String done) async {
    setState(() => _saving = true);
    try {
      final saved = await action();
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (saved != null) _fill(saved);
      });
      if (saved != null) widget.onSaved(saved);
      showThinkSnack(context, done);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final conflict = e is ThinkApiException && e.code == 'conflict';
      if (conflict) await _c.refreshMemories();
      if (mounted) showThinkSnack(context, e is ThinkApiException ? e.message : '저장하지 못했습니다: $e', error: true);
    }
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty || _content.text.trim().isEmpty) {
      showThinkSnack(context, '제목과 내용을 채워 주세요.', error: true);
      return;
    }
    final existing = widget.memory;
    await _run(() => _c.saveMemory(_draft(), existing: existing), '저장했습니다.');
  }

  Future<void> _approve() async {
    final m = widget.memory;
    if (m == null) return;
    if (_dirty) {
      _status = ThinkMemoryStatus.active;
      await _save();
      return;
    }
    await _run(() => _c.setMemoryStatus(m, ThinkMemoryStatus.active), '확정했습니다. 다음 대화부터 반영됩니다.');
  }

  Future<void> _delete() async {
    final m = widget.memory;
    if (m == null) return;
    final ok = await confirmThink(
      context,
      title: '기억 삭제',
      message: '"${m.title}"을(를) 지웁니다. 변경 이력도 함께 사라집니다.\n기록만 남기려면 상태를 "보관"으로 바꾸세요.',
      confirmLabel: '삭제',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _c.deleteMemory(m);
    } catch (e) {
      if (mounted) showThinkSnack(context, '삭제하지 못했습니다: $e', error: true);
    }
  }

  Future<void> _history() async {
    final m = widget.memory;
    if (m == null) return;
    final restored = await showDialog<ThinkMemoryRevision>(
      context: context,
      builder: (_) => _RevisionDialog(memory: m),
    );
    if (restored == null || !mounted) return;
    final latest = _c.memoryById(m.id) ?? m;
    await _run(() => _c.restoreRevision(latest, restored), 'v${restored.version} 내용으로 되돌렸습니다.');
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.memory;
    final isDecision = _kind == ThinkMemoryKind.decision;
    final ordered = _kind == ThinkMemoryKind.identity || _kind == ThinkMemoryKind.principle;
    final superseded = _c.memoryById(m?.supersedesId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
          child: Row(
            children: [
              Text(
                m == null ? '새 기억' : '기억 편집',
                style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800),
              ),
              if (m != null) ...[
                const SizedBox(width: 8),
                ThinkBadge('v${m.version}'),
              ],
              if (_dirty) ...[
                const SizedBox(width: 8),
                const ThinkBadge('수정 중', color: kThinkBlue),
              ],
              const Spacer(),
              if (m == null)
                TextButton(
                  onPressed: widget.onCancelNew,
                  child: const Text('취소', style: TextStyle(color: kThinkSub)),
                ),
              if (m != null) ...[
                IconButton(
                  tooltip: '변경 이력',
                  color: kThinkSub,
                  onPressed: _saving ? null : _history,
                  icon: const Icon(Icons.history),
                ),
                IconButton(
                  tooltip: '삭제',
                  color: kThinkSub,
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                ),
                if (m.kind == ThinkMemoryKind.decision && m.status == ThinkMemoryStatus.active) ...[
                  const SizedBox(width: 4),
                  OutlinedButton.icon(
                    onPressed: _saving || _dirty ? null : () => ThinkSpecExportDialog.show(context, m),
                    style: thinkOutlineButton(),
                    icon: const Icon(Icons.description_outlined, size: 16),
                    label: const Text('스펙 내보내기'),
                  ),
                ],
                if (m.status == ThinkMemoryStatus.draft) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _approve,
                    style: thinkOutlineButton(),
                    icon: const Icon(Icons.verified_outlined, size: 16, color: kThinkAccent),
                    label: const Text('확정하기'),
                  ),
                ],
              ],
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _saving || (m != null && !_dirty) ? null : _save,
                style: thinkPrimaryButton(),
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.save_outlined, size: 18),
                label: const Text('저장'),
              ),
            ],
          ),
        ),
        const Divider(color: kThinkBorder, height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<ThinkMemoryKind>(
                      key: ValueKey('kind-${m?.version}'),
                      initialValue: _kind,
                      dropdownColor: kThinkPanel,
                      style: const TextStyle(color: kThinkText, fontSize: 14),
                      decoration: thinkInputDecoration(label: '종류'),
                      items: [
                        for (final k in ThinkMemoryKind.values) DropdownMenuItem(value: k, child: Text(k.label)),
                      ],
                      onChanged: (v) => setState(() {
                        _kind = v ?? _kind;
                        _dirty = true;
                      }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<ThinkMemoryStatus>(
                      key: ValueKey('status-${m?.version}'),
                      initialValue: _status,
                      dropdownColor: kThinkPanel,
                      style: const TextStyle(color: kThinkText, fontSize: 14),
                      decoration: thinkInputDecoration(label: '상태'),
                      items: [
                        for (final s in ThinkMemoryStatus.values) DropdownMenuItem(value: s, child: Text(s.label)),
                      ],
                      onChanged: (v) => setState(() {
                        _status = v ?? _status;
                        _dirty = true;
                      }),
                    ),
                  ),
                  if (ordered) ...[
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: _sortOrder,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: kThinkText, fontSize: 14),
                        decoration: thinkInputDecoration(label: '순서'),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                switch (_kind) {
                  ThinkMemoryKind.identity => '교육철학·정체성: 확정 상태면 모든 대화에 전문이 들어갑니다. 길면 비용이 늘어납니다.',
                  ThinkMemoryKind.principle => '원칙: 확정 상태면 모든 대화에 요약이 들어갑니다.',
                  ThinkMemoryKind.decision => '결정: 최근 확정 결정 몇 개가 대화에 들어가고, 나머지는 질문과 관련 있을 때 찾아 씁니다.',
                  ThinkMemoryKind.note => '메모: 질문과 관련 있을 때만 찾아 씁니다.',
                },
                style: const TextStyle(color: kThinkHint, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 16),
              _field(_title, '제목'),
              const SizedBox(height: 12),
              _field(_content, isDecision ? '결정 내용' : '내용', lines: 10),
              if (isDecision) ...[
                const SizedBox(height: 12),
                _field(_context, '배경', lines: 3),
                const SizedBox(height: 12),
                _field(_reason, '이유', lines: 3),
                const SizedBox(height: 12),
                _field(_alternatives, '검토한 대안 (한 줄에 하나)', lines: 3),
              ],
              const SizedBox(height: 12),
              _field(_tags, '태그 (쉼표로 구분)'),
              if (m != null) ...[
                const SizedBox(height: 24),
                const Divider(color: kThinkBorder, height: 1),
                const SizedBox(height: 16),
                _meta('만든 때', formatDateTime(m.createdAt)),
                _meta('마지막 수정', formatDateTime(m.updatedAt)),
                if (m.approvedAt != null) _meta('확정한 때', formatDateTime(m.approvedAt)),
                if (m.specPath != null) _meta('내보낸 스펙', '${m.specPath} (${formatDateTime(m.specExportedAt)})'),
                if (superseded != null)
                  _metaLink('대체한 결정', superseded.title, () => _c.selectMemory(superseded.id)),
                if (m.sourceConversationId != null)
                  _metaLink('원본 대화', '대화 열기', () => _c.openConversation(m.sourceConversationId!)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String label, {int lines = 1}) {
    return TextField(
      controller: c,
      minLines: lines,
      maxLines: lines == 1 ? 1 : null,
      style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.6),
      decoration: thinkInputDecoration(label: label),
    );
  }

  Widget _meta(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 104, child: Text(k, style: const TextStyle(color: kThinkSub, fontSize: 12))),
          Expanded(child: SelectableText(v, style: const TextStyle(color: kThinkText, fontSize: 12))),
        ],
      ),
    );
  }

  Widget _metaLink(String k, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 104, child: Text(k, style: const TextStyle(color: kThinkSub, fontSize: 12))),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Text(label, style: const TextStyle(color: kThinkLink, fontSize: 12, decoration: TextDecoration.underline)),
          ),
        ],
      ),
    );
  }
}

class _RevisionDialog extends StatefulWidget {
  const _RevisionDialog({required this.memory});

  final ThinkMemory memory;

  @override
  State<_RevisionDialog> createState() => _RevisionDialogState();
}

class _RevisionDialogState extends State<_RevisionDialog> {
  List<ThinkMemoryRevision>? _revisions;
  String? _error;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    ThinkApi.instance.listRevisions(widget.memory.id).then((r) {
      if (mounted) setState(() => _revisions = r);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '이력을 불러오지 못했습니다: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final revs = _revisions;
    final current = revs == null || revs.isEmpty ? null : revs[_index.clamp(0, revs.length - 1)];
    final snap = current?.snapshot ?? const {};
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text('변경 이력 · ${widget.memory.title}',
          style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800, fontSize: 18)),
      content: SizedBox(
        width: 820,
        height: 560,
        child: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: kThinkSub)))
            : revs == null
                ? const Center(child: CircularProgressIndicator(color: kThinkAccent))
                : revs.isEmpty
                    ? const Center(child: Text('이력이 없습니다.', style: TextStyle(color: kThinkHint)))
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 200,
                            child: ListView.builder(
                              itemCount: revs.length,
                              itemBuilder: (_, i) {
                                final r = revs[i];
                                final sel = i == _index;
                                return Material(
                                  color: sel ? kThinkAccent.withValues(alpha: 0.16) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  child: InkWell(
                                    onTap: () => setState(() => _index = i),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'v${r.version}${r.version == widget.memory.version ? ' (현재)' : ''}',
                                            style: const TextStyle(color: kThinkText, fontSize: 13, fontWeight: FontWeight.w700),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(formatDateTime(r.changedAt), style: const TextStyle(color: kThinkHint, fontSize: 12)),
                                          Text(
                                            ThinkMemoryStatus.parse('${r.snapshot['status'] ?? ''}').label,
                                            style: const TextStyle(color: kThinkHint, fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: kThinkPanel,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: kThinkBorder),
                              ),
                              child: SingleChildScrollView(
                                child: SelectableText.rich(
                                  TextSpan(
                                    style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.6),
                                    children: [
                                      TextSpan(
                                        text: '${snap['title'] ?? ''}\n\n',
                                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                                      ),
                                      TextSpan(text: '${snap['content'] ?? ''}'),
                                      if ((snap['decision_context'] ?? '').toString().isNotEmpty)
                                        TextSpan(text: '\n\n[배경]\n${snap['decision_context']}'),
                                      if ((snap['decision_reason'] ?? '').toString().isNotEmpty)
                                        TextSpan(text: '\n\n[이유]\n${snap['decision_reason']}'),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
        if (current != null && current.version != widget.memory.version)
          ElevatedButton(
            onPressed: () => Navigator.pop(context, current),
            style: thinkPrimaryButton(),
            child: Text('v${current.version} 내용으로 되돌리기'),
          ),
      ],
    );
  }
}
