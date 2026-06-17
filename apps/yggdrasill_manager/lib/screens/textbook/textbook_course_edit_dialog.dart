import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class _CourseOption {
  final String key;
  final String label;
  final int orderIndex;
  const _CourseOption({
    required this.key,
    required this.label,
    required this.orderIndex,
  });
}

/// 과정(학년/레벨) 목록 편집 — `answer_key_grades` 테이블.
class TextbookCourseEditDialog extends StatefulWidget {
  const TextbookCourseEditDialog({
    super.key,
    required this.academyId,
  });

  final String academyId;

  static Future<bool> show(
    BuildContext context, {
    required String? defaultAcademyId,
  }) async {
    final academyId = await _resolveAcademyId(defaultAcademyId);
    if (!context.mounted) return false;
    if (academyId == null || academyId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('academy_id를 확인할 수 없습니다.')),
      );
      return false;
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => TextbookCourseEditDialog(academyId: academyId),
    );
    return saved == true;
  }

  static Future<String?> _resolveAcademyId(String? defaultAcademyId) async {
    final trimmed = defaultAcademyId?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    try {
      final row = await Supabase.instance.client
          .from('resource_files')
          .select('academy_id')
          .limit(1)
          .maybeSingle();
      final id = (row?['academy_id'] as String?)?.trim() ?? '';
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  @override
  State<TextbookCourseEditDialog> createState() =>
      _TextbookCourseEditDialogState();
}

class _TextbookCourseEditDialogState extends State<TextbookCourseEditDialog> {
  static const _accent = Color(0xFF33A373);
  static const _panelBg = Color(0xFF131315);
  static const _border = Color(0xFF2A2A2A);
  static const _text = Colors.white;
  static const _textSub = Color(0xFF9FB3B3);

  final _supabase = Supabase.instance.client;
  bool _loading = true;
  String? _loadError;
  List<_CourseOption> _editing = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final data = await _supabase
          .from('answer_key_grades')
          .select('grade_key,label,order_index')
          .eq('academy_id', widget.academyId)
          .order('order_index');
      final rows = (data as List).cast<Map<String, dynamic>>();
      final out = <_CourseOption>[];
      for (final r in rows) {
        final key = (r['grade_key'] as String?)?.trim() ?? '';
        final label = (r['label'] as String?)?.trim() ?? '';
        if (key.isEmpty || label.isEmpty) continue;
        out.add(_CourseOption(
          key: key,
          label: label,
          orderIndex: (r['order_index'] as num?)?.toInt() ?? 0,
        ));
      }
      out.sort((a, b) {
        final t = a.orderIndex.compareTo(b.orderIndex);
        if (t != 0) return t;
        return a.label.compareTo(b.label);
      });
      if (!mounted) return;
      setState(() {
        _editing = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '$e';
        _loading = false;
      });
    }
  }

  Future<String?> _promptCourseName({
    required String title,
    String? initialText,
  }) async {
    final ctrl = TextEditingController(text: initialText ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: _panelBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: Text(title,
              style: const TextStyle(color: _text, fontWeight: FontWeight.w900)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: _text, fontWeight: FontWeight.w700),
            cursorColor: _accent,
            decoration: InputDecoration(
              hintText: '과정 이름',
              hintStyle: const TextStyle(color: _textSub),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _accent, width: 1.4),
              ),
              filled: true,
              fillColor: const Color(0xFF1A1A1C),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('취소', style: TextStyle(color: _textSub)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              style: FilledButton.styleFrom(backgroundColor: _accent),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    final trimmed = result?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  Future<void> _save() async {
    final rows = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final item in _editing) {
      final label = item.label.trim();
      if (label.isEmpty) continue;
      if (seen.contains(label)) continue;
      seen.add(label);
      rows.add({
        'academy_id': widget.academyId,
        'grade_key': item.key,
        'label': label,
        'order_index': rows.length,
      });
    }
    try {
      await _supabase
          .from('answer_key_grades')
          .delete()
          .eq('academy_id', widget.academyId);
      if (rows.isNotEmpty) {
        await _supabase.from('answer_key_grades').insert(rows);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('과정 저장 실패: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _panelBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('과정 편집',
          style: TextStyle(color: _text, fontWeight: FontWeight.w900)),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _accent,
                  ),
                ),
              )
            : _loadError != null
                ? Text(_loadError!,
                    style: const TextStyle(color: Color(0xFFB74C4C)))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final name = await _promptCourseName(title: '과정 추가');
                            if (name == null) return;
                            setState(() {
                              _editing.add(_CourseOption(
                                key: const Uuid().v4(),
                                label: name,
                                orderIndex: _editing.length,
                              ));
                            });
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('과정 추가'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _text,
                            side: const BorderSide(color: _border),
                            backgroundColor: const Color(0xFF1A1A1C),
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_editing.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A1A1C),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _border),
                          ),
                          child: const Text(
                            '등록된 과정이 없습니다.\n“과정 추가”로 먼저 생성하세요.',
                            style: TextStyle(
                              color: _textSub,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              height: 1.4,
                            ),
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 360),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: _editing.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final item = _editing[index];
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1A1A1C),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: _border),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.label,
                                        style: const TextStyle(
                                          color: _text,
                                          fontWeight: FontWeight.w800,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '위로',
                                      onPressed: index == 0
                                          ? null
                                          : () => setState(() {
                                                final moved =
                                                    _editing.removeAt(index);
                                                _editing.insert(
                                                    index - 1, moved);
                                              }),
                                      icon: Icon(
                                        Icons.keyboard_arrow_up,
                                        size: 18,
                                        color: index == 0
                                            ? _textSub.withValues(alpha: 0.35)
                                            : _textSub,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '아래로',
                                      onPressed: index == _editing.length - 1
                                          ? null
                                          : () => setState(() {
                                                final moved =
                                                    _editing.removeAt(index);
                                                _editing.insert(
                                                    index + 1, moved);
                                              }),
                                      icon: Icon(
                                        Icons.keyboard_arrow_down,
                                        size: 18,
                                        color: index == _editing.length - 1
                                            ? _textSub.withValues(alpha: 0.35)
                                            : _textSub,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '이름 수정',
                                      onPressed: () async {
                                        final name = await _promptCourseName(
                                          title: '과정 이름 수정',
                                          initialText: item.label,
                                        );
                                        if (name == null) return;
                                        setState(() {
                                          _editing[index] = _CourseOption(
                                            key: item.key,
                                            label: name,
                                            orderIndex: item.orderIndex,
                                          );
                                        });
                                      },
                                      icon: const Icon(Icons.edit,
                                          size: 18, color: _textSub),
                                    ),
                                    IconButton(
                                      tooltip: '삭제',
                                      onPressed: () async {
                                        final ok = await showDialog<bool>(
                                          context: context,
                                          builder: (c) => AlertDialog(
                                            backgroundColor: _panelBg,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            title: const Text('과정 삭제',
                                                style: TextStyle(
                                                  color: _text,
                                                  fontWeight: FontWeight.w900,
                                                )),
                                            content: Text(
                                              '“${item.label}”을(를) 삭제할까요?',
                                              style: const TextStyle(
                                                  color: _textSub),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(c).pop(false),
                                                child: const Text('취소',
                                                    style: TextStyle(
                                                        color: _textSub)),
                                              ),
                                              FilledButton(
                                                onPressed: () =>
                                                    Navigator.of(c).pop(true),
                                                style: FilledButton.styleFrom(
                                                  backgroundColor:
                                                      const Color(0xFFB74C4C),
                                                ),
                                                child: const Text('삭제'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (ok != true) return;
                                        setState(() => _editing.removeAt(index));
                                      },
                                      icon: const Icon(Icons.delete_outline,
                                          size: 18, color: _textSub),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소', style: TextStyle(color: _textSub)),
        ),
        FilledButton(
          onPressed: _loading || _loadError != null ? null : _save,
          style: FilledButton.styleFrom(backgroundColor: _accent),
          child: const Text('저장'),
        ),
      ],
    );
  }
}
