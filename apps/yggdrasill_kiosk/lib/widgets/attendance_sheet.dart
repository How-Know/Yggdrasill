import 'dart:async';

import 'package:flutter/material.dart';

import '../models/kiosk_models.dart';
import '../services/korean_matcher.dart';

// 공용 FAB 커스텀 탭바 / 그룹 카드 토큰과 동일한 색상
// (apps/yggdrasill design_preview fab_tab_bar_preview.dart 기준).
//
// 탭바 원본은 반투명(#212121 50%) + BackdropFilter 블러지만, webOS에서는
// 이동 애니메이션 중 BackdropFilter가 깨져(시트 사라짐) 사용할 수 없다.
// 블러를 뺀 불투명 근사색으로 대체한다.
const Color _kSheetSurface = Color(0xFF202124);
const Color _kCardBackground = Color(0xFF121212);
const Color _kCardHighlight = Color(0x9A383838);

class AttendanceSheet extends StatefulWidget {
  const AttendanceSheet({
    super.key,
    required this.students,
    required this.onClose,
    required this.onReopen,
    required this.onSearch,
    required this.onCheckIn,
    required this.onCheckOut,
  });

  final List<StudentVisit> students;
  final VoidCallback onClose;
  final VoidCallback onReopen;
  final Future<List<StudentVisit>> Function(String query) onSearch;
  final Future<CheckInResult> Function(StudentVisit student, String pin)
  onCheckIn;
  final Future<CheckInResult> Function(StudentVisit student, String pin)
  onCheckOut;

  @override
  State<AttendanceSheet> createState() => _AttendanceSheetState();
}

class _AttendanceSheetState extends State<AttendanceSheet> {
  final _pin = StringBuffer();
  StudentVisit? _selected;
  bool _checkoutMode = false;
  String? _feedback;
  bool _submitting = false;

  void _select(StudentVisit student) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selected = student;
      _checkoutMode = student.checkedIn;
      _feedback = student.checkedIn
          ? '등원 중인 학생입니다. PIN을 입력하면 하원 처리됩니다.'
          : (student.scheduledToday
                ? null
                : '오늘 예정에 없는 학생입니다. 추가수업으로 등원 처리됩니다.');
      _pin.clear();
    });
  }

  Future<void> _openSearchDialog() async {
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onClose();
    await Future<void>.delayed(const Duration(milliseconds: 430));
    if (!mounted) return;
    final student = await showDialog<StudentVisit>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _StudentSearchDialog(
        students: widget.students,
        onSearch: widget.onSearch,
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    if (student == null || !mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    _select(student);
    widget.onReopen();
  }

  void _key(String value) {
    if (_submitting || _selected == null) return;
    var shouldSubmit = false;
    setState(() {
      _feedback = null;
      if (value == 'delete') {
        final text = _pin.toString();
        _pin.clear();
        if (text.isNotEmpty) _pin.write(text.substring(0, text.length - 1));
      } else if (_pin.length < 4) {
        _pin.write(value);
        shouldSubmit = _pin.length == 4;
      }
    });
    if (shouldSubmit) unawaited(_submit());
  }

  Future<void> _submit() async {
    final student = _selected;
    if (student == null || _pin.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final result = _checkoutMode
        ? await widget.onCheckOut(student, _pin.toString())
        : await widget.onCheckIn(student, _pin.toString());
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _feedback = result.message;
      _pin.clear();
      if (result.success) {
        _selected = null;
        _checkoutMode = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.horizontal(left: Radius.circular(64));
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: _kSheetSurface,
        borderRadius: radius,
        border: Border(
          left: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
          top: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
          bottom: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x44000000),
            blurRadius: 40,
            offset: Offset(-12, 0),
          ),
        ],
      ),
      child: Padding(
              padding: const EdgeInsets.fromLTRB(52, 48, 52, 44),
              child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _openSearchDialog,
                    icon: const Icon(Icons.search_rounded, size: 42),
                    label: const Text(
                      '학생 이름 검색',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.white.withValues(alpha: .09),
                      padding: const EdgeInsets.symmetric(vertical: 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded),
                  color: Colors.white,
                  iconSize: 48,
                ),
              ],
            ),
            const SizedBox(height: 34),
            Align(
              alignment: Alignment.centerLeft,
              child: const Text(
                '오늘 예정',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 27,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Expanded(
              flex: _selected == null ? 1 : 10,
              child: widget.students.isEmpty
                  ? const Center(
                      child: Text(
                        '표시할 학생이 없습니다.',
                        style: TextStyle(color: Colors.white38, fontSize: 30),
                      ),
                    )
                  : ListView.separated(
                      physics: const ClampingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      itemCount: widget.students.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 24),
                      itemBuilder: (context, index) {
                        final student = widget.students[index];
                        final selected = student.id == _selected?.id;
                        return Material(
                          color: selected
                              ? Color.alphaBlend(
                                  _kCardHighlight,
                                  _kCardBackground,
                                )
                              : _kCardBackground,
                          borderRadius: BorderRadius.circular(38),
                          child: InkWell(
                            onTap: () => _select(student),
                            borderRadius: BorderRadius.circular(38),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                                vertical: 46,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 195,
                                    child: Text(
                                      student.timeLabel.isEmpty
                                          ? '추가수업'
                                          : student.timeLabel,
                                      style: TextStyle(
                                        color: student.scheduledToday
                                            ? Colors.white54
                                            : const Color(0xFFFFC86A),
                                        fontSize: 44,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      student.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 60,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (student.checkedIn)
                                    const Text(
                                      '등원중',
                                      style: TextStyle(
                                        color: Color(0xFF79E2AE),
                                        fontSize: 44,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    )
                                  else
                                    const Icon(
                                      Icons.chevron_right_rounded,
                                      color: Colors.white38,
                                      size: 70,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_selected != null) ...[
              const SizedBox(height: 24),
              _buildPinPanel(),
            ],
              ],
              ),
      ),
    );
  }

  Widget _buildPinPanel() {
    return Align(
      alignment: Alignment.bottomRight,
      child: SizedBox(
        height: 900,
        child: Column(
          children: [
            const SizedBox(height: 40),
            Text(
              _checkoutMode
                  ? '${_selected!.name} 학생 하원 PIN'
                  : '${_selected!.name} 학생 PIN',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 40,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              List.filled(_pin.length, '●').join('  '),
              style: const TextStyle(color: Colors.white, fontSize: 54),
            ),
            SizedBox(
              height: 72,
              child: _feedback == null
                  ? null
                  : Center(
                      child: Text(
                        _feedback!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _feedback!.contains('완료')
                              ? const Color(0xFF79E2AE)
                              : const Color(0xFFFFB0A8),
                          fontSize: 30,
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: GridView.count(
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.65,
                children: [
                  for (final value in const [
                    '1',
                    '2',
                    '3',
                    '4',
                    '5',
                    '6',
                    '7',
                    '8',
                    '9',
                    '취소',
                    '0',
                    '지우기',
                  ])
                    FilledButton(
                      onPressed: () {
                        if (value == '취소') {
                          setState(() {
                            _selected = null;
                            _checkoutMode = false;
                            _pin.clear();
                            _feedback = null;
                          });
                        } else {
                          _key(value == '지우기' ? 'delete' : value);
                        }
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: .09),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22),
                        ),
                      ),
                      child: Text(
                        value,
                        style: TextStyle(
                          fontSize: value.length == 1 ? 58 : 38,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudentSearchDialog extends StatefulWidget {
  const _StudentSearchDialog({required this.students, required this.onSearch});

  final List<StudentVisit> students;
  final Future<List<StudentVisit>> Function(String query) onSearch;

  @override
  State<_StudentSearchDialog> createState() => _StudentSearchDialogState();
}

class _StudentSearchDialogState extends State<_StudentSearchDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<StudentVisit> _remoteResults = const [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  List<StudentVisit> get _results {
    final query = _controller.text.trim();
    if (query.isEmpty) return widget.students;
    final local = widget.students
        .where((student) => KoreanMatcher.matches(student.name, query))
        .toList();
    final known = local.map((student) => student.id).toSet();
    return [...local, ..._remoteResults.where((item) => known.add(item.id))];
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    setState(() => _remoteResults = const []);
    final query = value.trim();
    if (query.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      if (!mounted) return;
      setState(() => _searching = true);
      try {
        final results = await widget.onSearch(query);
        if (mounted && _controller.text.trim() == query) {
          setState(() => _remoteResults = results);
        }
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  void _choose(StudentVisit student) {
    if (student.checkedIn) return;
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(student);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight = media.size.height - media.viewInsets.bottom - 48;
    final dialogHeight = availableHeight.clamp(320.0, 760.0);
    final results = _results;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(36)),
      child: SizedBox(
        width: 980,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(34, 30, 34, 26),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      onChanged: _onChanged,
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(
                        color: Color(0xE6000000),
                        fontSize: 32,
                      ),
                      decoration: InputDecoration(
                        hintText: '학생 이름 또는 초성 검색',
                        prefixIcon: const Icon(Icons.search_rounded, size: 34),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                ),
                              )
                            : null,
                        filled: true,
                        fillColor: const Color(0xFFF1F3F6),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 22,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton.filledTonal(
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.close_rounded),
                    iconSize: 38,
                    padding: const EdgeInsets.all(18),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Expanded(
                child: results.isEmpty
                    ? const Center(
                        child: Text(
                          '검색 결과가 없습니다.',
                          style: TextStyle(
                            color: Color(0x61000000),
                            fontSize: 28,
                          ),
                        ),
                      )
                    : ListView.separated(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: results.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final student = results[index];
                          return Material(
                            color: const Color(0xFFF1F3F6),
                            borderRadius: BorderRadius.circular(24),
                            child: InkWell(
                              onTap: student.checkedIn
                                  ? null
                                  : () => _choose(student),
                              borderRadius: BorderRadius.circular(24),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 28,
                                  vertical: 22,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        student.name,
                                        style: TextStyle(
                                          color: student.checkedIn
                                              ? const Color(0x61000000)
                                              : const Color(0xE6000000),
                                          fontSize: 34,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      student.checkedIn
                                          ? '등원중'
                                          : student.scheduledToday
                                          ? '오늘 예정'
                                          : '추가수업',
                                      style: TextStyle(
                                        color: student.checkedIn
                                            ? const Color(0xFF299968)
                                            : const Color(0x99000000),
                                        fontSize: 25,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
