import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../models/kiosk_models.dart';
import '../services/korean_matcher.dart';

class AttendanceSheet extends StatefulWidget {
  const AttendanceSheet({
    super.key,
    required this.students,
    required this.onClose,
    required this.onSearch,
    required this.onCheckIn,
  });

  final List<StudentVisit> students;
  final VoidCallback onClose;
  final Future<List<StudentVisit>> Function(String query) onSearch;
  final Future<CheckInResult> Function(StudentVisit student, String pin)
  onCheckIn;

  @override
  State<AttendanceSheet> createState() => _AttendanceSheetState();
}

class _AttendanceSheetState extends State<AttendanceSheet> {
  final _searchController = TextEditingController();
  final _pin = StringBuffer();
  Timer? _debounce;
  List<StudentVisit> _remoteResults = const [];
  StudentVisit? _selected;
  String? _feedback;
  bool _searching = false;
  bool _submitting = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  List<StudentVisit> get _visibleStudents {
    final query = _searchController.text.trim();
    if (query.isEmpty) return widget.students;
    final local = widget.students
        .where((student) => KoreanMatcher.matches(student.name, query))
        .toList();
    final known = local.map((student) => student.id).toSet();
    return [...local, ..._remoteResults.where((item) => known.add(item.id))];
  }

  void _onSearchChanged(String value) {
    setState(() {
      _remoteResults = const [];
      _selected = null;
      _feedback = null;
      _pin.clear();
    });
    _debounce?.cancel();
    if (value.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() => _searching = true);
      try {
        final results = await widget.onSearch(value.trim());
        if (mounted && _searchController.text.trim() == value.trim()) {
          setState(() => _remoteResults = results);
        }
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  void _select(StudentVisit student) {
    if (student.checkedIn) return;
    setState(() {
      _selected = student;
      _feedback = student.scheduledToday
          ? null
          : '오늘 예정에 없는 학생입니다. 추가수업으로 등원 처리됩니다.';
      _pin.clear();
    });
  }

  void _key(String value) {
    if (_submitting || _selected == null) return;
    setState(() {
      _feedback = null;
      if (value == 'delete') {
        final text = _pin.toString();
        _pin.clear();
        if (text.isNotEmpty) _pin.write(text.substring(0, text.length - 1));
      } else if (_pin.length < 8) {
        _pin.write(value);
      }
    });
  }

  Future<void> _submit() async {
    final student = _selected;
    if (student == null || _pin.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final result = await widget.onCheckIn(student, _pin.toString());
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _feedback = result.message;
      _pin.clear();
      if (result.success) _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return YggGlassSurface(
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(64)),
      blurSigma: 34,
      tint: const Color(0xE6151922),
      padding: const EdgeInsets.fromLTRB(52, 48, 52, 44),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.search_rounded, size: 48, color: Colors.white70),
              const SizedBox(width: 22),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: const TextStyle(color: Colors.white, fontSize: 34),
                  decoration: InputDecoration(
                    hintText: '학생 이름 검색',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: .07),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 24,
                    ),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: CircularProgressIndicator(strokeWidth: 3),
                          )
                        : null,
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
            child: Text(
              _searchController.text.isEmpty ? '오늘 예정' : '검색 결과',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 27,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            flex: _selected == null ? 1 : 10,
            child: _visibleStudents.isEmpty
                ? const Center(
                    child: Text(
                      '표시할 학생이 없습니다.',
                      style: TextStyle(color: Colors.white38, fontSize: 30),
                    ),
                  )
                : ListView.separated(
                    itemCount: _visibleStudents.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final student = _visibleStudents[index];
                      final selected = student.id == _selected?.id;
                      return Material(
                        color: selected
                            ? const Color(0x385F9FFF)
                            : Colors.white.withValues(alpha: .055),
                        borderRadius: BorderRadius.circular(25),
                        child: InkWell(
                          onTap: student.checkedIn
                              ? null
                              : () => _select(student),
                          borderRadius: BorderRadius.circular(25),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 23,
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 150,
                                  child: Text(
                                    student.timeLabel.isEmpty
                                        ? '추가수업'
                                        : student.timeLabel,
                                    style: TextStyle(
                                      color: student.scheduledToday
                                          ? Colors.white54
                                          : const Color(0xFFFFC86A),
                                      fontSize: 25,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    student.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 33,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (student.checkedIn)
                                  const Text(
                                    '등원중',
                                    style: TextStyle(
                                      color: Color(0xFF79E2AE),
                                      fontSize: 25,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  )
                                else
                                  const Icon(
                                    Icons.chevron_right_rounded,
                                    color: Colors.white38,
                                    size: 38,
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
    );
  }

  Widget _buildPinPanel() {
    return Align(
      alignment: Alignment.bottomRight,
      child: SizedBox(
        height: 770,
        child: Column(
          children: [
            Text(
              '${_selected!.name} 학생 PIN',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 31,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              List.filled(_pin.length, '●').join('  '),
              style: const TextStyle(color: Colors.white, fontSize: 36),
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
                          fontSize: 22,
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
                          fontSize: value.length == 1 ? 31 : 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 76,
              child: FilledButton(
                onPressed: _pin.isEmpty || _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF5A9DFF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: _submitting
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        '확인',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
