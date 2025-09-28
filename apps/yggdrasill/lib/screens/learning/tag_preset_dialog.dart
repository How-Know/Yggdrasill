import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../services/tag_preset_service.dart';

class TagPresetDialog extends StatefulWidget {
  const TagPresetDialog({super.key});
  @override
  State<TagPresetDialog> createState() => _TagPresetDialogState();
}

class _TagPresetDialogState extends State<TagPresetDialog> {
  late Future<void> _initFuture;
  List<TagPreset> _presets = const [];
  bool _loading = true;

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

  Future<void> _addPreset() async {
    final nameController = TextEditingController();
    Color selected = const Color(0xFF1976D2);
    IconData icon = Icons.edit_note;
    final palette = [
      const Color(0xFFEF5350), const Color(0xFFAB47BC), const Color(0xFF7E57C2), const Color(0xFF5C6BC0),
      const Color(0xFF42A5F5), const Color(0xFF26A69A), const Color(0xFF66BB6A), const Color(0xFFFFCA28),
      const Color(0xFFF57C00), const Color(0xFF8D6E63), const Color(0xFFBDBDBD), const Color(0xFF90A4AE),
    ];
    final icons = [
      Icons.bedtime, Icons.phone_iphone, Icons.edit_note, Icons.record_voice_over, Icons.gesture, Icons.flag, Icons.timer,
    ];
    final preset = await showDialog<TagPreset>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: const Text('태그 프리셋 추가', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('이름', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: '예: 기록',
                    hintStyle: TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Color(0xFF2A2A2A),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('색상', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in palette)
                      GestureDetector(
                        onTap: () => setLocal(() => selected = c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(color: c == selected ? Colors.white : Colors.white24, width: c == selected ? 2 : 1),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('아이콘', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final ic in icons)
                      GestureDetector(
                        onTap: () => setLocal(() => icon = ic),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: ic == icon ? Colors.white : Colors.white24),
                          ),
                          child: Icon(ic, color: ic == icon ? Colors.white : Colors.white70, size: 20),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                Navigator.of(ctx).pop(TagPreset(id: const Uuid().v4(), name: name, color: selected, icon: icon, orderIndex: 9999));
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white),
              child: const Text('추가'),
            ),
          ],
        ),
      ),
    );
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
      backgroundColor: const Color(0xFF1F1F1F),
      title: Row(
        children: [
          const Text('태그 프리셋 관리', style: TextStyle(color: Colors.white70)),
          const Spacer(),
          IconButton(onPressed: _addPreset, icon: const Icon(Icons.add, color: Colors.white70)),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 480,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Colors.white70))
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
                  color: const Color(0xFF232326),
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  child: child,
                );
              },
              itemBuilder: (context, i) {
                final p = _presets[i];
                return ListTile(
                  key: ValueKey(p.id),
                  leading: CircleAvatar(backgroundColor: p.color, child: Icon(p.icon, color: Colors.white)),
                  title: Text(p.name, style: const TextStyle(color: Colors.white70)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '수정',
                        onPressed: () async {
                          final edited = await _editPreset(context, p);
                          if (edited != null) {
                            await TagPresetService.instance.upsert(edited);
                            setState(() {
                              _presets = _presets.map((e) => e.id == edited.id ? edited : e).toList();
                            });
                          }
                        },
                        icon: const Icon(Icons.edit, color: Colors.white60),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
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
                        icon: const Icon(Icons.delete, color: Colors.white54),
                      ),
                      const SizedBox(width: 12),
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
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
      ],
    );
  }

  Future<TagPreset?> _editPreset(BuildContext context, TagPreset original) async {
    final nameController = TextEditingController(text: original.name);
    Color selected = original.color;
    IconData icon = original.icon;
    final palette = [
      const Color(0xFFEF5350), const Color(0xFFAB47BC), const Color(0xFF7E57C2), const Color(0xFF5C6BC0),
      const Color(0xFF42A5F5), const Color(0xFF26A69A), const Color(0xFF66BB6A), const Color(0xFFFFCA28),
      const Color(0xFFF57C00), const Color(0xFF8D6E63), const Color(0xFFBDBDBD), const Color(0xFF90A4AE),
    ];
    final icons = [
      Icons.bedtime, Icons.phone_iphone, Icons.edit_note, Icons.record_voice_over, Icons.gesture, Icons.flag, Icons.timer,
    ];
    return showDialog<TagPreset>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: const Text('태그 프리셋 수정', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('이름', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: '예: 기록',
                    hintStyle: TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Color(0xFF2A2A2A),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('색상', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in palette)
                      GestureDetector(
                        onTap: () => setLocal(() => selected = c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(color: c == selected ? Colors.white : Colors.white24, width: c == selected ? 2 : 1),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('아이콘', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final ic in icons)
                      GestureDetector(
                        onTap: () => setLocal(() => icon = ic),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: ic == icon ? Colors.white : Colors.white24),
                          ),
                          child: Icon(ic, color: ic == icon ? Colors.white : Colors.white70, size: 20),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                Navigator.of(ctx).pop(TagPreset(id: original.id, name: name, color: selected, icon: icon, orderIndex: original.orderIndex));
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }
}


