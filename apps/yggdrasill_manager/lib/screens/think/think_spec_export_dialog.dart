import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../services/think/think_api.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_markdown.dart';
import 'think_style.dart';

String? findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final hasDocs = Directory(p.join(dir.path, 'docs')).existsSync();
    final hasSupabase = Directory(p.join(dir.path, 'supabase')).existsSync();
    if (hasDocs && hasSupabase) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// 확정된 결정을 Cursor가 읽을 수 있는 마크다운 스펙으로 내보낸다.
class ThinkSpecExportDialog extends StatefulWidget {
  const ThinkSpecExportDialog({super.key, required this.memory});

  final ThinkMemory memory;

  static Future<void> show(BuildContext context, ThinkMemory memory) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ThinkSpecExportDialog(memory: memory),
    );
  }

  @override
  State<ThinkSpecExportDialog> createState() => _ThinkSpecExportDialogState();
}

class _ThinkSpecExportDialogState extends State<ThinkSpecExportDialog> {
  final _markdown = TextEditingController();
  String _suggestedPath = '';
  bool _loading = true;
  bool _saving = false;
  bool _preview = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _markdown.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ThinkApi.instance.specExport(widget.memory.id);
      if (!mounted) return;
      _markdown.text = res.markdown;
      setState(() {
        _suggestedPath = res.suggestedPath;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ThinkApiException ? e.message : '스펙을 만들지 못했습니다: $e';
        _loading = false;
      });
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _markdown.text));
    if (mounted) showThinkSnack(context, '마크다운을 복사했습니다.');
  }

  Future<void> _saveFile() async {
    final root = findRepoRoot();
    String? initialDir;
    if (root != null) {
      final specs = Directory(p.join(root, 'docs', 'specs'));
      if (!specs.existsSync()) specs.createSync(recursive: true);
      initialDir = specs.path;
    }
    final picked = await FilePicker.platform.saveFile(
      dialogTitle: '스펙 저장',
      fileName: p.basename(_suggestedPath.isEmpty ? 'decision.md' : _suggestedPath),
      initialDirectory: initialDir,
      type: FileType.custom,
      allowedExtensions: const ['md'],
    );
    if (picked == null) return;
    final path = picked.toLowerCase().endsWith('.md') ? picked : '$picked.md';
    setState(() => _saving = true);
    try {
      await File(path).writeAsString(_markdown.text, flush: true);
      final stored = root != null && p.isWithin(root, path)
          ? p.relative(path, from: root).replaceAll(r'\', '/')
          : path;
      final latest = ThinkController.instance.memoryById(widget.memory.id) ?? widget.memory;
      try {
        await ThinkController.instance.markSpecExported(latest, stored);
      } catch (_) {
        await ThinkController.instance.refreshMemories();
      }
      if (!mounted) return;
      showThinkSnack(context, '저장했습니다: $stored');
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showThinkSnack(context, '파일을 저장하지 못했습니다: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kThinkBg,
      shape: thinkDialogShape,
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      title: Row(
        children: [
          const Icon(Icons.description_outlined, color: kThinkAccent, size: 24),
          const SizedBox(width: 12),
          const Text('스펙으로 내보내기', style: TextStyle(color: kThinkText, fontWeight: FontWeight.w800, fontSize: 20)),
          const Spacer(),
          if (!_loading && _error == null)
            ThinkToggleChip(
              label: '미리보기',
              icon: Icons.visibility_outlined,
              selected: _preview,
              onChanged: (v) => setState(() => _preview = v),
            ),
        ],
      ),
      content: SizedBox(width: 860, height: 640, child: _body()),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('닫기', style: TextStyle(color: kThinkSub)),
        ),
        if (_error != null)
          ElevatedButton(onPressed: _load, style: thinkPrimaryButton(), child: const Text('다시 시도')),
        if (!_loading && _error == null) ...[
          OutlinedButton.icon(
            onPressed: _saving ? null : _copy,
            style: thinkOutlineButton(),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('복사'),
          ),
          ElevatedButton.icon(
            onPressed: _saving ? null : _saveFile,
            style: thinkPrimaryButton(),
            icon: const Icon(Icons.save_alt, size: 18),
            label: const Text('파일로 저장'),
          ),
        ],
      ],
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: kThinkAccent),
            SizedBox(height: 16),
            Text('결정을 스펙 문서로 정리하는 중…', style: TextStyle(color: kThinkSub)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(child: ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '권장 위치: $_suggestedPath  ·  저장한 파일을 Cursor에서 열어 구현 지시로 쓰면 됩니다.',
          style: const TextStyle(color: kThinkSub, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _preview
              ? Container(
                  decoration: BoxDecoration(
                    color: kThinkPanel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kThinkBorder),
                  ),
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: ThinkMarkdown(_markdown.text),
                    ),
                  ),
                )
              : TextField(
                  controller: _markdown,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(color: kThinkText, fontSize: 13, height: 1.5, fontFamily: 'monospace'),
                  decoration: thinkInputDecoration(),
                ),
        ),
      ],
    );
  }
}
