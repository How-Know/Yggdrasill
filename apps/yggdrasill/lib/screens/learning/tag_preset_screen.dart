import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../services/tag_preset_service.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

class TagPresetScreen extends StatefulWidget {
  const TagPresetScreen({super.key});
  @override
  State<TagPresetScreen> createState() => _TagPresetScreenState();
}

class _TagPresetScreenState extends State<TagPresetScreen> {
  late Future<List<TagPreset>> _future;

  @override
  void initState() {
    super.initState();
    _future = TagPresetService.instance.loadPresets();
  }

  Future<void> _addPreset() async {
    final nameController = ImeAwareTextEditingController();
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
      final list = await TagPresetService.instance.loadPresets();
      final updated = <TagPreset>[...list, preset]
          .asMap()
          .entries
          .map((e) => TagPreset(id: e.value.id, name: e.value.name, color: e.value.color, icon: e.value.icon, orderIndex: e.key))
          .toList();
      await TagPresetService.instance.saveAll(updated);
      setState(() => _future = TagPresetService.instance.loadPresets());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text('태그 프리셋 관리', style: TextStyle(color: Colors.white70)),
        actions: [
          IconButton(onPressed: _addPreset, icon: const Icon(Icons.add, color: Colors.white70)),
        ],
      ),
      body: FutureBuilder<List<TagPreset>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(color: Colors.white70));
          }
          final presets = snap.data!;
          return ReorderableListView.builder(
            itemCount: presets.length,
            onReorder: (o, n) async {
              final list = [...presets];
              final item = list.removeAt(o);
              list.insert(n > o ? n - 1 : n, item);
              for (int i = 0; i < list.length; i++) {
                list[i] = TagPreset(id: list[i].id, name: list[i].name, color: list[i].color, icon: list[i].icon, orderIndex: i);
              }
              await TagPresetService.instance.saveAll(list);
              setState(() => _future = TagPresetService.instance.loadPresets());
            },
            itemBuilder: (context, i) {
              final p = presets[i];
              return ListTile(
                key: ValueKey(p.id),
                leading: CircleAvatar(backgroundColor: p.color, child: Icon(p.icon, color: Colors.white)),
                title: Text(p.name, style: const TextStyle(color: Colors.white70)),
                trailing: IconButton(
                  onPressed: () async {
                    await TagPresetService.instance.delete(p.id);
                    setState(() => _future = TagPresetService.instance.loadPresets());
                  },
                  icon: const Icon(Icons.delete, color: Colors.white54),
                ),
              );
            },
          );
        },
      ),
    );
  }
}




