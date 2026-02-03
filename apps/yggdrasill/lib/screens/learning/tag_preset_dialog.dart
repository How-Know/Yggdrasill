import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../services/tag_preset_service.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import '../../widgets/dialog_tokens.dart';

class TagPresetDialog extends StatefulWidget {
  const TagPresetDialog({super.key});
  @override
  State<TagPresetDialog> createState() => _TagPresetDialogState();
}

class _TagPresetDialogState extends State<TagPresetDialog> {
  late Future<void> _initFuture;
  List<TagPreset> _presets = const [];
  bool _loading = true;
  static const List<Color> _palette = [
    Color(0xFFEF5350),
    Color(0xFFAB47BC),
    Color(0xFF7E57C2),
    Color(0xFF5C6BC0),
    Color(0xFF42A5F5),
    Color(0xFF26A69A),
    Color(0xFF66BB6A),
    Color(0xFFFFCA28),
    Color(0xFFF57C00),
    Color(0xFF8D6E63),
    Color(0xFFBDBDBD),
    Color(0xFF90A4AE),
  ];
  static const List<IconData> _icons = [
    Icons.bedtime,
    Icons.phone_iphone,
    Icons.edit_note,
    Icons.record_voice_over,
    Icons.gesture,
    Icons.flag,
    Icons.timer,
  ];

  @override
  void initState() {
    super.initState();
    _initFuture = _loadInitial();
  }

  Future<void> _loadInitial() async {
    final list = await TagPresetService.instance.loadPresets();
    if (!mounted) return;
    setState(() {
      _presets = list;
      _loading = false;
    });
  }

  InputDecoration _fieldDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: kDlgTextSub),
      filled: true,
      fillColor: kDlgFieldBg,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: kDlgBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: kDlgAccent),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
      ),
    );
  }

  Future<TagPreset?> _showPresetEditor({TagPreset? original}) async {
    return showDialog<TagPreset>(
      context: context,
      builder: (_) => _TagPresetEditorDialog(
        original: original,
        fieldDecorationBuilder: _fieldDecoration,
        sectionLabelBuilder: _sectionLabel,
        palette: _palette,
        icons: _icons,
      ),
    );
  }

  Future<void> _addPreset() async {
    final preset = await _showPresetEditor();
    if (preset != null) {
      final updated = <TagPreset>[..._presets, preset]
          .asMap()
          .entries
          .map((e) => TagPreset(id: e.value.id, name: e.value.name, color: e.value.color, icon: e.value.icon, orderIndex: e.key))
          .toList();
      await TagPresetService.instance.saveAll(updated);
      if (!mounted) return;
      setState(() {
        _presets = updated;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kDlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: Row(
        children: [
          const Text('태그 프리셋 관리', style: TextStyle(color: kDlgText, fontSize: 20, fontWeight: FontWeight.w900)),
          const Spacer(),
          IconButton(
            tooltip: '추가',
            onPressed: _addPreset,
            icon: const Icon(Icons.add, color: kDlgTextSub),
          ),
        ],
      ),
      content: SizedBox(
        width: 496,
        height: 416,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: kDlgTextSub))
            : ReorderableListView.builder(
                itemCount: _presets.length,
                buildDefaultDragHandles: false,
                onReorder: (o, n) async {
                  final list = [..._presets];
                  final item = list.removeAt(o);
                  list.insert(n > o ? n - 1 : n, item);
                  final normalized = <TagPreset>[];
                  for (int i = 0; i < list.length; i++) {
                    normalized.add(TagPreset(id: list[i].id, name: list[i].name, color: list[i].color, icon: list[i].icon, orderIndex: i));
                  }
                  await TagPresetService.instance.saveAll(normalized);
                  setState(() {
                    _presets = normalized;
                  });
                },
                proxyDecorator: (child, index, animation) {
                  return Material(
                    color: kDlgPanelBg,
                    elevation: 4,
                    borderRadius: BorderRadius.circular(10),
                    child: child,
                  );
                },
                itemBuilder: (context, i) {
                  final p = _presets[i];
                  return Container(
                    key: ValueKey(p.id),
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: kDlgFieldBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kDlgBorder),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: p.color, width: 1.2),
                          ),
                          child: Icon(p.icon, color: p.color, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            p.name,
                            style: const TextStyle(color: kDlgText, fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          tooltip: '수정',
                          onPressed: () async {
                            final edited = await _showPresetEditor(original: p);
                            if (edited != null) {
                                final next = _presets.map((e) => e.id == edited.id ? edited : e).toList();
                                final normalized = <TagPreset>[];
                                for (int i = 0; i < next.length; i++) {
                                  normalized.add(TagPreset(
                                    id: next[i].id,
                                    name: next[i].name,
                                    color: next[i].color,
                                    icon: next[i].icon,
                                    orderIndex: i,
                                  ));
                                }
                                await TagPresetService.instance.saveAll(normalized);
                                setState(() {
                                  _presets = normalized;
                                });
                            }
                          },
                          icon: const Icon(Icons.edit, color: kDlgTextSub),
                        ),
                        IconButton(
                          tooltip: '삭제',
                          onPressed: () async {
                            await TagPresetService.instance.delete(p.id);
                            final list = [..._presets]..removeWhere((e) => e.id == p.id);
                            final normalized = <TagPreset>[];
                            for (int i = 0; i < list.length; i++) {
                              normalized.add(TagPreset(id: list[i].id, name: list[i].name, color: list[i].color, icon: list[i].icon, orderIndex: i));
                            }
                            await TagPresetService.instance.saveAll(normalized);
                            setState(() {
                              _presets = normalized;
                            });
                          },
                          icon: const Icon(Icons.delete, color: kDlgTextSub),
                        ),
                        const SizedBox(width: 6),
                        ReorderableDragStartListener(
                          index: i,
                          child: Icon(Icons.drag_handle, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}

class _TagPresetEditorDialog extends StatefulWidget {
  final TagPreset? original;
  final InputDecoration Function(String) fieldDecorationBuilder;
  final Widget Function(String) sectionLabelBuilder;
  final List<Color> palette;
  final List<IconData> icons;

  const _TagPresetEditorDialog({
    required this.original,
    required this.fieldDecorationBuilder,
    required this.sectionLabelBuilder,
    required this.palette,
    required this.icons,
  });

  @override
  State<_TagPresetEditorDialog> createState() => _TagPresetEditorDialogState();
}

class _TagPresetEditorDialogState extends State<_TagPresetEditorDialog> {
  late final ImeAwareTextEditingController _nameController;
  late String _draftName;
  late Color _selected;
  late IconData _icon;

  @override
  void initState() {
    super.initState();
    _nameController = ImeAwareTextEditingController(text: widget.original?.name ?? '');
    _draftName = _nameController.text;
    _selected = widget.original?.color ?? const Color(0xFF1976D2);
    _icon = widget.original?.icon ?? Icons.edit_note;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _handleSave() {
    FocusScope.of(context).unfocus();
    _nameController.value = _nameController.value.copyWith(composing: TextRange.empty);
    final name = (_draftName.trim().isEmpty ? _nameController.text.trim() : _draftName.trim());
    if (name.isEmpty) return;
    Navigator.of(context).pop(TagPreset(
      id: widget.original?.id ?? const Uuid().v4(),
      name: name,
      color: _selected,
      icon: _icon,
      orderIndex: widget.original?.orderIndex ?? 9999,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.original == null ? '태그 프리셋 추가' : '태그 프리셋 수정';
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kDlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: Text(
        title,
        style: const TextStyle(color: kDlgText, fontSize: 20, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.sectionLabelBuilder('이름'),
              TextField(
                controller: _nameController,
                onChanged: (value) => _draftName = value,
                style: const TextStyle(color: kDlgText),
                decoration: widget.fieldDecorationBuilder('예: 기록'),
              ),
              const SizedBox(height: 14),
              widget.sectionLabelBuilder('색상'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in widget.palette)
                    GestureDetector(
                      onTap: () => setState(() => _selected = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c == _selected ? Colors.white : Colors.white24,
                            width: c == _selected ? 2 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              widget.sectionLabelBuilder('아이콘'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final ic in widget.icons)
                    GestureDetector(
                      onTap: () => setState(() => _icon = ic),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: kDlgFieldBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: ic == _icon ? Colors.white : Colors.white24),
                        ),
                        child: Icon(ic, color: ic == _icon ? Colors.white : Colors.white70, size: 20),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          child: const Text('저장', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}




