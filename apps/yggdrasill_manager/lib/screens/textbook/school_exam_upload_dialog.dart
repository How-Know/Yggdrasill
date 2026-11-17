import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../services/school_exam_file_info.dart';
import '../../services/school_exam_review_service.dart';
import 'school_exam_panel.dart';

/// 한 번에 올릴 수 있는 시험지 수(문제은행 일괄 등록과 같다)
const int maxSchoolExamUploads = 10;

// 문제은행 "내신 기출 일괄 등록" 창이 쓰던 색 그대로.
const Color _bg = Color(0xFF171717);
const Color _panel = Color(0xFF202020);
const Color _field = Color(0xFF292929);
const Color _border = Color(0xFF3A3A3A);
const Color _text = Color(0xFFF3F3F3);
const Color _textSub = Color(0xFF9EAAAA);
const Color _accent = Color(0xFF2C8C66);
const Color _accentText = Color(0xFF73C9A5);
const Color _pdfAccent = Color(0xFFE57373);
const Color _dangerText = Color(0xFFFFA8AF);
const Color _dangerBg = Color(0xFF2A1B1F);
const Color _dangerBorder = Color(0xFF6E353B);
const Color _warnText = Color(0xFFEAB968);

/// 업로드 창 결과: 올린 시험지 수와 처음 올린 시험지의 학교(목록에서 바로 고르게)
class SchoolExamUploadResult {
  const SchoolExamUploadResult({required this.uploaded, this.firstSchoolName});

  final int uploaded;
  final String? firstSchoolName;
}

/// 내신기출 업로드: 시험지 PDF(필수)와 같은 이름의 HWPX(있으면)를 묶어 올리고, 추출이 끝나면 바로 검수가 돈다.
Future<SchoolExamUploadResult?> showSchoolExamUploadDialog(
  BuildContext context, {
  required SchoolExamController controller,
}) {
  return showDialog<SchoolExamUploadResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SchoolExamUploadDialog(controller: controller),
  );
}

enum _RowPhase { idle, uploading, done, failed }

class _RowState {
  const _RowState(this.phase, [this.message = '']);

  final _RowPhase phase;
  final String message;
}

class _SchoolExamUploadDialog extends StatefulWidget {
  const _SchoolExamUploadDialog({required this.controller});

  final SchoolExamController controller;

  @override
  State<_SchoolExamUploadDialog> createState() => _SchoolExamUploadDialogState();
}

class _SchoolExamUploadDialogState extends State<_SchoolExamUploadDialog> {
  final Map<String, String> _pdfByKey = <String, String>{};
  final Map<String, String> _hwpxByKey = <String, String>{};
  final Map<String, SchoolExamFileInfo> _infoByKey = <String, SchoolExamFileInfo>{};
  final Map<String, _RowState> _stateByKey = <String, _RowState>{};
  bool _pdfHover = false;
  bool _hwpxHover = false;
  bool _uploading = false;
  bool _cancelRequested = false;
  String _message = '';
  String? _firstSchoolName;

  String _pairKey(String path) => p.basenameWithoutExtension(path).trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  List<String> get _keys => _pdfByKey.keys.toList()..sort();

  List<String> get _hwpxWithoutPdf => [
        for (final key in _hwpxByKey.keys.toList()..sort())
          if (!_pdfByKey.containsKey(key)) p.basename(_hwpxByKey[key]!),
      ];

  int get _doneCount => _stateByKey.values.where((s) => s.phase == _RowPhase.done).length;

  bool _locked(String key) {
    final phase = _stateByKey[key]?.phase;
    return phase == _RowPhase.uploading || phase == _RowPhase.done;
  }

  String _examKeyOf(SchoolExamFileInfo info) => schoolExamKey(
        schoolName: info.schoolName,
        examYear: info.examYear,
        gradeKey: info.gradeKey,
        semesterLabel: info.semesterLabel,
        examTermLabel: info.examTermLabel,
        courseKey: info.courseKey,
        essayPart: info.essayPart,
      );

  /// 같은 시험지가 이미 있거나 이번에 두 번 올리는지 알려 준다(막지는 않는다).
  String _duplicateNote(String key) {
    final info = _infoByKey[key];
    if (info == null || !info.isComplete) return '';
    final examKey = _examKeyOf(info);
    for (final other in _keys) {
      if (other == key) continue;
      final o = _infoByKey[other];
      if (o != null && o.isComplete && _examKeyOf(o) == examKey) return '이번에 올리는 다른 파일과 같은 시험지입니다';
    }
    for (final doc in widget.controller.allExams) {
      if (doc.examKey != examKey) continue;
      return doc.published
          ? '같은 시험지가 이미 등록되어 있습니다(${doc.sourceFilename}). 올리면 문서가 하나 더 생깁니다'
          : '같은 시험지 초안이 이미 있습니다(${doc.sourceFilename})';
    }
    return '';
  }

  void _addPaths(Iterable<String> paths, String extension) {
    final target = extension == '.pdf' ? _pdfByKey : _hwpxByKey;
    var skipped = 0;
    for (final raw in paths) {
      final path = raw.trim();
      if (path.isEmpty || p.extension(path).toLowerCase() != extension) {
        skipped += 1;
        continue;
      }
      final key = _pairKey(path);
      if (key.isEmpty || _locked(key)) continue;
      target[key] = path;
      _infoByKey.putIfAbsent(key, () => SchoolExamFileInfo.parse(p.basename(path)));
    }
    setState(() {
      _message = skipped == 0 ? '' : '$skipped개 파일은 ${extension.substring(1).toUpperCase()} 형식이 아니라 제외했습니다.';
    });
  }

  Future<void> _pickFiles(String extension) async {
    if (_uploading) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: <String>[extension.substring(1)],
      withData: false,
    );
    if (result == null) return;
    _addPaths(result.files.map((file) => file.path ?? '').where((path) => path.isNotEmpty), extension);
  }

  void _remove(String key) {
    if (_locked(key)) return;
    setState(() {
      _pdfByKey.remove(key);
      _hwpxByKey.remove(key);
      _infoByKey.remove(key);
      _stateByKey.remove(key);
    });
  }

  Future<void> _submit() async {
    final pending = [for (final key in _keys) if (_stateByKey[key]?.phase != _RowPhase.done) key];
    if (pending.isEmpty) {
      setState(() => _message = '시험지 PDF 를 하나 이상 넣으세요.');
      return;
    }
    if (_keys.length > maxSchoolExamUploads) {
      setState(() => _message = '한 번에 최대 $maxSchoolExamUploads부만 올릴 수 있습니다.');
      return;
    }
    final incomplete = [for (final key in pending) if (!(_infoByKey[key]?.isComplete ?? false)) key];
    if (incomplete.isNotEmpty) {
      setState(() => _message = '분류가 빠진 시험지가 ${incomplete.length}부 있습니다. 빨간 표시 항목을 채우세요.');
      return;
    }
    setState(() {
      _uploading = true;
      _cancelRequested = false;
      _message = '';
    });
    final service = widget.controller.service;
    try {
      final academyId = widget.controller.academyId ?? await service.resolveAcademyId();
      for (final key in pending) {
        if (_cancelRequested || !mounted) break;
        final info = _infoByKey[key]!;
        final pdfPath = _pdfByKey[key]!;
        final hwpxPath = _hwpxByKey[key];
        setState(() => _stateByKey[key] = const _RowState(_RowPhase.uploading));
        try {
          final pdfBytes = await File(pdfPath).readAsBytes();
          final hwpxBytes = hwpxPath == null ? null : await File(hwpxPath).readAsBytes();
          final result = await service.uploadAndStart(
            academyId: academyId,
            upload: SchoolExamUpload(
              info: info,
              pdfName: p.basename(pdfPath),
              pdfBytes: pdfBytes,
              hwpxName: hwpxPath == null ? '' : p.basename(hwpxPath),
              hwpxBytes: hwpxBytes,
            ),
          );
          _firstSchoolName ??= info.schoolName;
          if (!mounted) return;
          setState(() => _stateByKey[key] = _RowState(_RowPhase.done, result.warning));
        } catch (e) {
          if (!mounted) return;
          setState(() => _stateByKey[key] = _RowState(_RowPhase.failed, SchoolExamReviewService.describeError(e)));
        }
      }
    } catch (e) {
      if (mounted) setState(() => _message = '업로드를 시작하지 못했습니다: ${SchoolExamReviewService.describeError(e)}');
    }
    if (!mounted) return;
    final failed = _stateByKey.values.where((s) => s.phase == _RowPhase.failed).length;
    setState(() {
      _uploading = false;
      if (_message.isEmpty) {
        _message = _cancelRequested
            ? '남은 업로드를 멈췄습니다. 올린 시험지 $_doneCount부는 추출이 끝나면 검수가 이어집니다.'
            : failed > 0
                ? '실패 $failed부. 내용을 확인하고 다시 올리세요.'
                : '';
      }
    });
    unawaited(widget.controller.load(silent: true));
  }

  void _close() {
    final done = _doneCount;
    Navigator.of(context).pop(done == 0 ? null : SchoolExamUploadResult(uploaded: done, firstSchoolName: _firstSchoolName));
  }

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    final orphanHwpx = _hwpxWithoutPdf;
    final pendingCount = keys.where((k) => _stateByKey[k]?.phase != _RowPhase.done).length;
    final allDone = keys.isNotEmpty && pendingCount == 0;
    return Dialog(
      backgroundColor: _bg,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 820),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '내신기출 업로드',
                          style: TextStyle(color: _text, fontSize: 20, fontWeight: FontWeight.w900),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '시험지 PDF 와 이름이 같은 HWPX 를 한 부로 묶습니다. 그림은 PDF 에서 잘라 쓰고, '
                          '추출이 끝나면 바로 검수가 돕니다. 한 번에 최대 10부.',
                          style: TextStyle(color: _textSub, fontSize: 12, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _uploading ? null : _close,
                    icon: const Icon(Icons.close, color: _textSub),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _DropZone(
                      title: 'PDF 파일 (필수)',
                      subtitle: '끌어다 놓거나 눌러서 고르기',
                      icon: Icons.picture_as_pdf_outlined,
                      active: _pdfHover,
                      count: _pdfByKey.length,
                      accent: _pdfAccent,
                      enabled: !_uploading,
                      onTap: () => unawaited(_pickFiles('.pdf')),
                      onEntered: () => setState(() => _pdfHover = true),
                      onExited: () => setState(() => _pdfHover = false),
                      onDropped: (paths) {
                        setState(() => _pdfHover = false);
                        _addPaths(paths, '.pdf');
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DropZone(
                      title: 'HWPX 파일',
                      subtitle: 'PDF 와 같은 파일 이름 · 없으면 PDF 에서 본문을 읽습니다',
                      icon: Icons.upload_file_outlined,
                      active: _hwpxHover,
                      count: _hwpxByKey.length,
                      accent: _accent,
                      enabled: !_uploading,
                      onTap: () => unawaited(_pickFiles('.hwpx')),
                      onEntered: () => setState(() => _hwpxHover = true),
                      onExited: () => setState(() => _hwpxHover = false),
                      onDropped: (paths) {
                        setState(() => _hwpxHover = false);
                        _addPaths(paths, '.hwpx');
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: _panel,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _border),
                  ),
                  child: keys.isEmpty && orphanHwpx.isEmpty
                      ? const Center(
                          child: Text('넣은 파일이 없습니다.', style: TextStyle(color: _textSub)),
                        )
                      : ListView(
                          padding: const EdgeInsets.all(10),
                          children: [
                            for (var index = 0; index < keys.length; index++)
                              _UploadRow(
                                key: ValueKey(keys[index]),
                                index: index,
                                baseName: p.basenameWithoutExtension(_pdfByKey[keys[index]]!),
                                hasHwpx: _hwpxByKey.containsKey(keys[index]),
                                info: _infoByKey[keys[index]]!,
                                state: _stateByKey[keys[index]] ?? const _RowState(_RowPhase.idle),
                                duplicateNote: _duplicateNote(keys[index]),
                                locked: _uploading || _locked(keys[index]),
                                onChanged: (info) => setState(() => _infoByKey[keys[index]] = info),
                                onRemove: () => _remove(keys[index]),
                              ),
                            if (orphanHwpx.isNotEmpty)
                              Container(
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: _dangerBg,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: _dangerBorder),
                                ),
                                child: Text(
                                  'PDF 짝이 없어 올리지 않는 HWPX: ${orphanHwpx.join(', ')}',
                                  style: const TextStyle(color: _dangerText, fontSize: 12, height: 1.4),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              if (_message.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _message,
                  style: const TextStyle(color: _dangerText, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    '시험지 ${keys.length}/$maxSchoolExamUploads부${_doneCount > 0 ? ' · 올림 $_doneCount부' : ''}',
                    style: const TextStyle(color: _textSub, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  if (_uploading)
                    TextButton(
                      onPressed: _cancelRequested ? null : () => setState(() => _cancelRequested = true),
                      child: Text(_cancelRequested ? '이번 파일까지만 올립니다' : '남은 업로드 멈춤'),
                    )
                  else
                    TextButton(onPressed: _close, child: Text(_doneCount > 0 ? '닫기' : '취소')),
                  const SizedBox(width: 8),
                  if (allDone)
                    FilledButton.icon(
                      onPressed: _close,
                      style: FilledButton.styleFrom(backgroundColor: _accent),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('목록에서 보기'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _uploading || pendingCount == 0 ? null : () => unawaited(_submit()),
                      style: FilledButton.styleFrom(backgroundColor: _accent),
                      icon: _uploading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.playlist_add_check_rounded, size: 18),
                      label: Text(_uploading ? '올리는 중' : '$pendingCount부 올리고 추출·검수 시작'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.active,
    required this.count,
    required this.accent,
    required this.enabled,
    required this.onTap,
    required this.onEntered,
    required this.onExited,
    required this.onDropped,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool active;
  final int count;
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onEntered;
  final VoidCallback onExited;
  final ValueChanged<List<String>> onDropped;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) => onEntered(),
      onDragExited: (_) => onExited(),
      onDragDone: (detail) => onDropped(detail.files.map((file) => file.path).toList()),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 96,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: active ? accent.withValues(alpha: 0.15) : _field,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: active ? accent : _border, width: active ? 2 : 1),
          ),
          child: Row(
            children: [
              Icon(icon, color: accent, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$title · $count개',
                      style: const TextStyle(color: _text, fontSize: 14, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _textSub, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 시험지 한 부: 파일 이름, 파일에서 읽은 분류(고칠 수 있다), 올리는 상태.
class _UploadRow extends StatefulWidget {
  const _UploadRow({
    super.key,
    required this.index,
    required this.baseName,
    required this.hasHwpx,
    required this.info,
    required this.state,
    required this.duplicateNote,
    required this.locked,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final String baseName;
  final bool hasHwpx;
  final SchoolExamFileInfo info;
  final _RowState state;
  final String duplicateNote;
  final bool locked;
  final ValueChanged<SchoolExamFileInfo> onChanged;
  final VoidCallback onRemove;

  @override
  State<_UploadRow> createState() => _UploadRowState();
}

class _UploadRowState extends State<_UploadRow> {
  late final TextEditingController _yearCtrl =
      TextEditingController(text: widget.info.examYear == null ? '' : '${widget.info.examYear}');
  late final TextEditingController _schoolCtrl = TextEditingController(text: widget.info.schoolShortName);

  @override
  void dispose() {
    _yearCtrl.dispose();
    _schoolCtrl.dispose();
    super.dispose();
  }

  SchoolExamFileInfo get _info => widget.info;

  void _setYear(String raw) {
    final year = int.tryParse(raw.trim());
    widget.onChanged(_info.withExamYear(year != null && year >= 2000 && year <= 2099 ? year : null));
  }

  void _setGrade(String? gradeKey) {
    if (gradeKey == null || gradeKey.length != 2) return;
    final level = gradeKey.startsWith('H') ? 'high' : 'middle';
    widget.onChanged(
      _info
          .copyWith(
            schoolLevel: level,
            grade: int.parse(gradeKey.substring(1)),
            // 중등 과정은 학년·학기에서 다시 정한다.
            courseKey: level == 'middle' || level != _info.schoolLevel ? '' : null,
          )
          .normalized(),
    );
  }

  void _setSemester(String? semester) {
    if (semester == null) return;
    widget.onChanged(
      _info.copyWith(semesterLabel: semester, courseKey: _info.schoolLevel == 'middle' ? '' : null).normalized(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final missing = info.missing;
    final state = widget.state;
    final locked = widget.locked;
    // 학교 이름으로 학교급을 알면 그 학교급의 학년만 고르게 한다.
    final schoolLevel = info.schoolShortName.endsWith('고')
        ? 'high'
        : (info.schoolShortName.endsWith('중') ? 'middle' : '');
    final gradeItems = <(String, String)>[
      if (schoolLevel != 'high') ...const [('M1', '중1'), ('M2', '중2'), ('M3', '중3')],
      if (schoolLevel != 'middle') ...const [('H1', '고1'), ('H2', '고2'), ('H3', '고3')],
    ];
    final courseItems = <(String, String)>[
      for (final c in kSchoolExamCourses)
        if (c.schoolLevel == info.schoolLevel) (c.key, c.label),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
      decoration: BoxDecoration(
        color: _field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: state.phase == _RowPhase.failed ? _dangerBorder : _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${widget.index + 1}',
                  style: const TextStyle(color: _textSub, fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
              Expanded(
                child: Text(
                  widget.baseName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _text, fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              const _Chip(label: 'PDF', fg: _accentText),
              const SizedBox(width: 4),
              _Chip(label: widget.hasHwpx ? 'HWPX' : 'HWPX 없음', fg: widget.hasHwpx ? _accentText : _textSub),
              if (info.essayPart) ...[
                const SizedBox(width: 4),
                const _Chip(label: '서술형', fg: _warnText),
              ],
              const SizedBox(width: 8),
              if (state.phase == _RowPhase.uploading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _accentText),
                  ),
                )
              else if (state.phase == _RowPhase.done)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(Icons.check_circle_rounded, size: 18, color: _accentText),
                )
              else
                IconButton(
                  onPressed: locked ? null : widget.onRemove,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 16, color: _textSub),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 24, right: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _textBox(
                  label: '연도',
                  width: 72,
                  controller: _yearCtrl,
                  invalid: missing.contains('연도'),
                  digitsOnly: true,
                  onChanged: _setYear,
                ),
                _textBox(
                  label: '학교',
                  width: 112,
                  controller: _schoolCtrl,
                  invalid: missing.contains('학교'),
                  hint: '경신중',
                  onChanged: (v) => widget.onChanged(_info.withSchool(v)),
                ),
                _dropdown(
                  label: '학년',
                  width: 80,
                  value: gradeItems.any((g) => g.$1 == info.gradeKey) ? info.gradeKey : null,
                  items: gradeItems,
                  invalid: missing.contains('학년'),
                  onChanged: _setGrade,
                ),
                _dropdown(
                  label: '학기',
                  width: 88,
                  value: info.semesterLabel.isEmpty ? null : info.semesterLabel,
                  items: const [('1학기', '1학기'), ('2학기', '2학기')],
                  invalid: missing.contains('학기'),
                  onChanged: _setSemester,
                ),
                _dropdown(
                  label: '시험',
                  width: 80,
                  value: info.examTermLabel.isEmpty ? null : info.examTermLabel,
                  items: const [('중간', '중간'), ('기말', '기말')],
                  invalid: missing.contains('중간·기말'),
                  onChanged: (v) {
                    if (v != null) widget.onChanged(_info.copyWith(examTermLabel: v).normalized());
                  },
                ),
                _dropdown(
                  label: '과정',
                  width: 136,
                  value: courseItems.any((c) => c.$1 == info.courseKey) ? info.courseKey : null,
                  items: courseItems,
                  invalid: missing.contains('과정'),
                  onChanged: (v) {
                    if (v != null) widget.onChanged(_info.copyWith(courseKey: v).normalized());
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 8, 0),
            child: _buildNote(info, missing, state),
          ),
        ],
      ),
    );
  }

  Widget _buildNote(SchoolExamFileInfo info, List<String> missing, _RowState state) {
    final String text;
    final Color color;
    if (state.phase == _RowPhase.failed) {
      text = '올리지 못했습니다: ${state.message}';
      color = _dangerText;
    } else if (state.phase == _RowPhase.done) {
      text = state.message.isEmpty
          ? '올렸습니다. 본문 추출이 끝나면 바로 검수가 돕니다.'
          : '초안은 만들었지만 검수를 예약하지 못했습니다(${state.message}). 목록에서 "검수 시작"을 누르세요.';
      color = state.message.isEmpty ? _accentText : _warnText;
    } else if (state.phase == _RowPhase.uploading) {
      text = '올리는 중';
      color = _textSub;
    } else if (missing.isNotEmpty) {
      text = '채워야 할 항목: ${missing.join(', ')}';
      color = _dangerText;
    } else if (widget.duplicateNote.isNotEmpty) {
      text = '${info.schoolName} ${info.title} · ${widget.duplicateNote}';
      color = _warnText;
    } else {
      text = '${info.schoolName} ${info.title}';
      color = _textSub;
    }
    return Text(text, style: TextStyle(color: color, fontSize: 12, height: 1.4));
  }

  Widget _labeled(String label, double width, bool invalid, Widget child) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: invalid ? _dangerText : _textSub, fontSize: 11)),
          const SizedBox(height: 4),
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: invalid ? _dangerBorder : _border),
            ),
            child: child,
          ),
        ],
      ),
    );
  }

  Widget _textBox({
    required String label,
    required double width,
    required TextEditingController controller,
    required bool invalid,
    required ValueChanged<String> onChanged,
    bool digitsOnly = false,
    String hint = '',
  }) {
    return _labeled(
      label,
      width,
      invalid,
      TextField(
        controller: controller,
        enabled: !widget.locked,
        onChanged: onChanged,
        keyboardType: digitsOnly ? TextInputType.number : TextInputType.text,
        inputFormatters: digitsOnly
            ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)]
            : [LengthLimitingTextInputFormatter(20)],
        style: const TextStyle(color: _text, fontSize: 12.5),
        decoration: InputDecoration(
          isDense: true,
          isCollapsed: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: const TextStyle(color: _textSub, fontSize: 12.5),
        ),
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required double width,
    required String? value,
    required List<(String, String)> items,
    required bool invalid,
    required ValueChanged<String?> onChanged,
  }) {
    return _labeled(
      label,
      width,
      invalid,
      DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: _panel,
          iconSize: 16,
          iconEnabledColor: _textSub,
          hint: const Text('선택', style: TextStyle(color: _textSub, fontSize: 12.5)),
          style: const TextStyle(color: _text, fontSize: 12.5),
          items: [
            for (final (key, text) in items) DropdownMenuItem<String>(value: key, child: Text(text)),
          ],
          onChanged: widget.locked ? null : onChanged,
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.fg});

  final String label;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: fg.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w800)),
    );
  }
}
