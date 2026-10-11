import 'package:flutter/material.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import '../../services/think/think_tree.dart';
import 'think_style.dart';

/// 폴더 선택 결과에서 '최상위'를 뜻하는 값.
const String kThinkRootFolder = '__root__';

String _preview(String text, int max) {
  final line = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return line.length <= max ? line : '${line.substring(0, max)}…';
}

/// 옮길 폴더를 고른다. [movingFolderId]를 주면 그 폴더와 하위 폴더는 고를 수 없다.
/// [allowRoot]가 false면 '최상위'를 빼고 폴더만 고르게 한다.
Future<String?> showThinkFolderPicker(
  BuildContext context, {
  required ThinkTree tree,
  String? movingFolderId,
  String? currentParentId,
  bool allowRoot = true,
  String title = '어디로 옮길까요?',
}) {
  final folders = tree.folders();
  Widget option(String value, String label, int depth, {bool enabled = true, bool current = false}) {
    return InkWell(
      onTap: enabled && !current ? () => Navigator.pop(context, value) : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12 + depth * 16.0, 10, 12, 10),
        child: Row(
          children: [
            Icon(
              value == kThinkRootFolder ? Icons.vertical_align_top : Icons.folder_outlined,
              size: 16,
              color: enabled ? kThinkSub : kThinkHint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: enabled && !current ? kThinkText : kThinkHint, fontSize: 13),
              ),
            ),
            if (current) const ThinkBadge('현재 위치'),
          ],
        ),
      ),
    );
  }

  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(title, style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 420,
        height: 360,
        child: ListView(
          children: [
            if (allowRoot) option(kThinkRootFolder, '최상위', 0, current: currentParentId == null),
            for (final f in folders)
              option(
                f.folder.id,
                f.folder.title,
                allowRoot ? f.depth + 1 : f.depth,
                enabled: movingFolderId == null || !tree.isInside(f.folder.id, movingFolderId),
                current: f.folder.id == currentParentId,
              ),
            if (folders.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('아직 폴더가 없습니다. 트리의 + 버튼으로 먼저 만드세요.', style: TextStyle(color: kThinkHint, fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
      ],
    ),
  );
}

/// 대화의 문답을 트리에 발췌로 남긴다. 발췌는 원본 메시지를 가리키기만 하고 AI 맥락에는 들어가지 않는다.
class ThinkExcerptDialog extends StatefulWidget {
  const ThinkExcerptDialog._({this.conversationId, this.messages = const [], this.initialIds = const {}, this.node});

  final String? conversationId;
  final List<ThinkMessage> messages;
  final Set<String> initialIds;
  final ThinkTreeNode? node;

  static Future<bool> create(
    BuildContext context, {
    required String conversationId,
    required List<ThinkMessage> messages,
    required int index,
  }) async {
    final withIds = messages.where((m) => (m.id ?? '').isNotEmpty).toList();
    final initial = {
      for (final i in thinkTurnIndices(messages, index))
        if ((messages[i].id ?? '').isNotEmpty) messages[i].id!,
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ThinkExcerptDialog._(conversationId: conversationId, messages: withIds, initialIds: initial),
    );
    return ok == true;
  }

  static Future<bool> edit(BuildContext context, ThinkTreeNode node) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => ThinkExcerptDialog._(node: node));
    return ok == true;
  }

  @override
  State<ThinkExcerptDialog> createState() => _ThinkExcerptDialogState();
}

class _ThinkExcerptDialogState extends State<ThinkExcerptDialog> {
  ThinkController get _c => ThinkController.instance;

  late final TextEditingController _title;
  late final TextEditingController _summary;
  late final Set<String> _selected = {...widget.initialIds};
  String _folder = kThinkRootFolder;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.node != null;

  @override
  void initState() {
    super.initState();
    final node = widget.node;
    if (node != null) {
      _title = TextEditingController(text: node.title);
      _summary = TextEditingController(text: node.summary ?? '');
      return;
    }
    final question = widget.messages.where((m) => widget.initialIds.contains(m.id) && m.isUser).firstOrNull;
    _title = TextEditingController(text: question == null ? '' : _preview(question.content, 40));
    _summary = TextEditingController();
    final placed = _c.tree.conversationNodes[widget.conversationId];
    if (placed?.parentId != null) _folder = placed!.parentId!;
  }

  @override
  void dispose() {
    _title.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '제목을 입력하세요.');
      return;
    }
    if (!_editing && _selected.isEmpty) {
      setState(() => _error = '발췌할 메시지를 하나 이상 고르세요.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_editing) {
        await _c.updateExcerpt(widget.node!, title: title, summary: _summary.text);
      } else {
        await _c.createExcerpt(
          conversationId: widget.conversationId!,
          parentId: _folder == kThinkRootFolder ? null : _folder,
          title: title,
          summary: _summary.text,
          messageIds: [
            for (final m in widget.messages)
              if (_selected.contains(m.id)) m.id!,
          ],
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = ThinkApi.treeErrorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tree = _c.tree;
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(
        _editing ? '발췌 편집' : '트리에 발췌로 남기기',
        style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                autofocus: true,
                style: const TextStyle(color: kThinkText, fontSize: 14),
                decoration: thinkInputDecoration(label: '제목'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _summary,
                minLines: 2,
                maxLines: 6,
                style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
                decoration: thinkInputDecoration(label: '요약 (선택)', hint: '나중에 보고 알아볼 수 있게 한두 줄로'),
              ),
              if (!_editing) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _folder,
                  dropdownColor: kThinkPanel,
                  style: const TextStyle(color: kThinkText, fontSize: 14),
                  iconEnabledColor: kThinkSub,
                  decoration: thinkInputDecoration(label: '넣을 곳'),
                  items: [
                    const DropdownMenuItem(value: kThinkRootFolder, child: Text('최상위')),
                    for (final f in tree.folders())
                      DropdownMenuItem(
                        value: f.folder.id,
                        child: Text(tree.folderPath(f.folder.id), overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _folder = v ?? kThinkRootFolder),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('출처 메시지', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Text('${_selected.length}개 선택', style: const TextStyle(color: kThinkHint, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 280),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kThinkBorder),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: widget.messages.length,
                    itemBuilder: (_, i) => _messageOption(widget.messages[i]),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: kThinkHint),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '발췌는 정리용입니다. 원본 메시지를 가리키기만 하고 AI 답변에는 쓰이지 않습니다.',
                      style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('취소', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: thinkPrimaryButton(),
          child: Text(_saving ? '저장 중…' : (_editing ? '저장' : '만들기')),
        ),
      ],
    );
  }

  Widget _messageOption(ThinkMessage m) {
    final checked = _selected.contains(m.id);
    return InkWell(
      onTap: () => setState(() => checked ? _selected.remove(m.id) : _selected.add(m.id!)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: checked,
              visualDensity: VisualDensity.compact,
              activeColor: kThinkAccent,
              side: const BorderSide(color: kThinkSub),
              onChanged: (v) => setState(() => v == true ? _selected.add(m.id!) : _selected.remove(m.id)),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 44,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  m.isUser ? '질문' : 'Think',
                  style: TextStyle(color: m.isUser ? kThinkSub : kThinkAccent, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Text(
                  _preview(m.content, 160),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: m.contextExcluded ? kThinkHint : kThinkText, fontSize: 12, height: 1.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 선택한 메시지 출처로 종합 문서를 작성해 폴더에 저장한다. AI 맥락·발췌와 구분된다.
class ThinkDocumentDialog extends StatefulWidget {
  const ThinkDocumentDialog._({
    this.conversationId,
    this.messages = const [],
    this.initialIds = const {},
    this.nodeId,
  });

  final String? conversationId;
  final List<ThinkMessage> messages;
  final Set<String> initialIds;
  final String? nodeId;

  static Future<bool> create(
    BuildContext context, {
    required String conversationId,
    required List<ThinkMessage> messages,
    required int index,
  }) async {
    final withIds = messages.where((m) => (m.id ?? '').isNotEmpty).toList();
    final initial = {
      for (final i in thinkTurnIndices(messages, index))
        if ((messages[i].id ?? '').isNotEmpty) messages[i].id!,
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ThinkDocumentDialog._(conversationId: conversationId, messages: withIds, initialIds: initial),
    );
    return ok == true;
  }

  static Future<bool> open(BuildContext context, String nodeId) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => ThinkDocumentDialog._(nodeId: nodeId));
    return ok == true;
  }

  @override
  State<ThinkDocumentDialog> createState() => _ThinkDocumentDialogState();
}

class _ThinkDocumentDialogState extends State<ThinkDocumentDialog> {
  ThinkController get _c => ThinkController.instance;

  late final TextEditingController _title;
  late final TextEditingController _body;
  late final Set<String> _selected = {...widget.initialIds};
  String _folder = kThinkRootFolder;
  bool _saving = false;
  bool _loading = false;
  String? _error;
  ThinkDocumentDetail? _detail;

  bool get _creating => widget.nodeId == null;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    _body = TextEditingController();
    if (widget.nodeId != null) {
      _loading = true;
      _c.loadDocument(widget.nodeId!).then((d) {
        if (!mounted) return;
        setState(() {
          _detail = d;
          _title.text = d.title;
          _body.text = d.body;
          _loading = false;
        });
      }).catchError((e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = ThinkApi.treeErrorMessage(e);
        });
      });
      return;
    }
    final question = widget.messages.where((m) => widget.initialIds.contains(m.id) && m.isUser).firstOrNull;
    _title.text = question == null ? '' : _preview(question.content, 40);
    final placed = _c.tree.conversationNodes[widget.conversationId];
    if (placed?.parentId != null) _folder = placed!.parentId!;
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final body = _body.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '제목을 입력하세요.');
      return;
    }
    if (body.isEmpty) {
      setState(() => _error = '본문을 입력하세요.');
      return;
    }
    if (_creating && _selected.isEmpty) {
      setState(() => _error = '출처로 연결할 메시지를 하나 이상 고르세요.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_creating) {
        await _c.createDocument(
          conversationId: widget.conversationId!,
          parentId: _folder == kThinkRootFolder ? null : _folder,
          title: title,
          body: body,
          messageIds: [
            for (final m in widget.messages)
              if (_selected.contains(m.id)) m.id!,
          ],
        );
      } else {
        final d = _detail!;
        await _c.updateDocument(d, title: title, body: body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = ThinkApi.treeErrorMessage(e);
        });
      }
    }
  }

  Future<void> _goSources() async {
    final d = _detail;
    if (d == null || d.sourceMessageIds.isEmpty) return;
    if (mounted) Navigator.pop(context, false);
    await _c.revealMessages(d.conversationId, d.sourceMessageIds);
  }

  @override
  Widget build(BuildContext context) {
    final tree = _c.tree;
    if (_loading) {
      return AlertDialog(
        backgroundColor: kThinkBg,
        shape: thinkDialogShape,
        content: const SizedBox(width: 320, height: 80, child: Center(child: CircularProgressIndicator())),
      );
    }
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      title: Text(
        _creating ? '폴더에 종합 문서 저장' : '종합 문서',
        style: const TextStyle(color: kThinkText, fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                autofocus: _creating,
                style: const TextStyle(color: kThinkText, fontSize: 14),
                decoration: thinkInputDecoration(label: '제목'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _body,
                minLines: 4,
                maxLines: 14,
                style: const TextStyle(color: kThinkText, fontSize: 14, height: 1.5),
                decoration: thinkInputDecoration(label: '본문', hint: '발췌 요약과 별도로 정리할 내용'),
              ),
              if (_creating) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _folder,
                  dropdownColor: kThinkPanel,
                  style: const TextStyle(color: kThinkText, fontSize: 14),
                  iconEnabledColor: kThinkSub,
                  decoration: thinkInputDecoration(label: '저장할 폴더'),
                  items: [
                    const DropdownMenuItem(value: kThinkRootFolder, child: Text('최상위')),
                    for (final f in tree.folders())
                      DropdownMenuItem(
                        value: f.folder.id,
                        child: Text(tree.folderPath(f.folder.id), overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _folder = v ?? kThinkRootFolder),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('출처 메시지', style: TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Text('${_selected.length}개 선택', style: const TextStyle(color: kThinkHint, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kThinkBorder),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: widget.messages.length,
                    itemBuilder: (_, i) => _messageOption(widget.messages[i]),
                  ),
                ),
              ] else if (_detail != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _detail!.sourceMessageIds.isEmpty ? null : _goSources,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text('출처 원문 보기 (${_detail!.sourceMessageIds.length}개)'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: kThinkHint),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '종합 문서는 정리용입니다. AI 답변 맥락에는 들어가지 않습니다. 출처 메시지가 지워지면 문서 전체가 삭제됩니다.',
                      style: TextStyle(color: kThinkHint, fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: thinkPrimaryButton(),
          child: Text(_saving ? '저장 중…' : (_creating ? '폴더에 저장' : '저장')),
        ),
      ],
    );
  }

  Widget _messageOption(ThinkMessage m) {
    final checked = _selected.contains(m.id);
    return InkWell(
      onTap: () => setState(() => checked ? _selected.remove(m.id) : _selected.add(m.id!)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: checked,
              visualDensity: VisualDensity.compact,
              activeColor: kThinkAccent,
              side: const BorderSide(color: kThinkSub),
              onChanged: (v) => setState(() => v == true ? _selected.add(m.id!) : _selected.remove(m.id)),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 44,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  m.isUser ? '질문' : 'Think',
                  style: TextStyle(color: m.isUser ? kThinkSub : kThinkAccent, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Text(
                  _preview(m.content, 160),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: m.contextExcluded ? kThinkHint : kThinkText, fontSize: 12, height: 1.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
