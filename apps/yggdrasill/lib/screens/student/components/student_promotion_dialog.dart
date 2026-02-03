import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/dialog_tokens.dart';
import '../../../widgets/pill_tab_selector.dart';
import '../../../widgets/app_snackbar.dart';

class StudentPromotionDialog extends StatefulWidget {
  final List<StudentWithInfo> students;
  const StudentPromotionDialog({super.key, required this.students});

  @override
  State<StudentPromotionDialog> createState() => _StudentPromotionDialogState();
}

class _StudentPromotionDialogState extends State<StudentPromotionDialog> {
  static const String _draftKey = 'student_promotion_draft_v1';

  bool _useCustomScope = false;
  bool _loadingDraft = true;
  bool _saving = false;

  final Set<String> _selectedGradeKeys = <String>{};
  final Set<String> _selectedStudentIds = <String>{};
  final Map<String, String> _newSchoolByStudentId = <String, String>{};
  final Map<String, TextEditingController> _schoolControllers = {};

  @override
  void initState() {
    super.initState();
    _loadDraft();
  }

  @override
  void dispose() {
    for (final controller in _schoolControllers.values) {
      controller.dispose();
    }
    _schoolControllers.clear();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftKey);
      if (raw == null || raw.trim().isEmpty) {
        if (mounted) setState(() => _loadingDraft = false);
        return;
      }
      final Map<String, dynamic> data = jsonDecode(raw);
      final bool useCustom = data['useCustom'] == true;
      final List<dynamic> gradeKeys = (data['gradeKeys'] as List?) ?? const [];
      final List<dynamic> studentIds = (data['studentIds'] as List?) ?? const [];
      final Map<String, dynamic> schoolMap = (data['newSchools'] as Map?)?.cast<String, dynamic>() ?? const {};

      _useCustomScope = useCustom;
      _selectedGradeKeys
        ..clear()
        ..addAll(gradeKeys.map((e) => e.toString()));
      _selectedStudentIds
        ..clear()
        ..addAll(studentIds.map((e) => e.toString()));
      _newSchoolByStudentId
        ..clear()
        ..addAll(schoolMap.map((k, v) => MapEntry(k, v.toString())));

      _resetSchoolControllers();
    } catch (_) {
      // ignore: draft 파싱 실패 시 빈 상태로 유지
    } finally {
      if (mounted) setState(() => _loadingDraft = false);
    }
  }

  Future<void> _saveDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'useCustom': _useCustomScope,
      'gradeKeys': _selectedGradeKeys.toList(),
      'studentIds': _selectedStudentIds.toList(),
      'newSchools': _newSchoolByStudentId,
    };
    await prefs.setString(_draftKey, jsonEncode(payload));
  }

  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey);
  }

  void _resetSchoolControllers() {
    for (final controller in _schoolControllers.values) {
      controller.dispose();
    }
    _schoolControllers.clear();
  }

  String _gradeKey(EducationLevel level, int grade) => '${level.index}:$grade';

  String _gradeLabel(EducationLevel level, int grade) {
    if (level == EducationLevel.high && grade == 4) return 'N수';
    final prefix = switch (level) {
      EducationLevel.elementary => '초',
      EducationLevel.middle => '중',
      EducationLevel.high => '고',
    };
    return '$prefix$grade';
  }

  List<_GradeOption> _gradeOptions() {
    return <_GradeOption>[
      for (final g in gradesByLevel[EducationLevel.elementary] ?? const <Grade>[])
        _GradeOption(EducationLevel.elementary, g.value, _gradeLabel(EducationLevel.elementary, g.value)),
      for (final g in gradesByLevel[EducationLevel.middle] ?? const <Grade>[])
        _GradeOption(EducationLevel.middle, g.value, _gradeLabel(EducationLevel.middle, g.value)),
      for (final g in gradesByLevel[EducationLevel.high] ?? const <Grade>[])
        _GradeOption(EducationLevel.high, g.value, _gradeLabel(EducationLevel.high, g.value)),
    ];
  }

  int _maxGradeFor(EducationLevel level) {
    final grades = gradesByLevel[level] ?? const <Grade>[];
    if (grades.isEmpty) return 0;
    return grades.map((g) => g.value).reduce((a, b) => a > b ? a : b);
  }

  TextEditingController _schoolControllerFor(String studentId, String initialValue) {
    return _schoolControllers.putIfAbsent(
      studentId,
      () => ImeAwareTextEditingController(text: initialValue),
    );
  }

  String _enteredSchoolFor(String studentId) {
    final controller = _schoolControllers[studentId];
    if (controller != null) return controller.text;
    return _newSchoolByStudentId[studentId] ?? '';
  }

  Set<String> _selectedIdsByGrade() {
    if (_selectedGradeKeys.isEmpty) return <String>{};
    final ids = <String>{};
    for (final s in widget.students) {
      final key = _gradeKey(s.student.educationLevel, s.student.grade);
      if (_selectedGradeKeys.contains(key)) {
        ids.add(s.student.id);
      }
    }
    return ids;
  }

  Set<String> _effectiveSelectedIds() {
    if (!_useCustomScope) {
      return widget.students.map((s) => s.student.id).toSet();
    }
    final byGrade = _selectedIdsByGrade();
    final byStudent = _selectedStudentIds;
    return {...byGrade, ...byStudent};
  }

  List<StudentWithInfo> _scopeStudents() {
    final ids = _effectiveSelectedIds();
    return widget.students.where((s) => ids.contains(s.student.id)).toList();
  }

  _PromotionInfo _promotionInfo(Student s) {
    final grade = s.grade <= 0 ? 1 : s.grade;
    switch (s.educationLevel) {
      case EducationLevel.elementary:
        if (grade >= _maxGradeFor(EducationLevel.elementary)) {
          return _PromotionInfo(
            nextLevel: EducationLevel.middle,
            nextGrade: 1,
            levelChanged: true,
          );
        }
        return _PromotionInfo(
          nextLevel: s.educationLevel,
          nextGrade: grade + 1,
          levelChanged: false,
        );
      case EducationLevel.middle:
        if (grade >= _maxGradeFor(EducationLevel.middle)) {
          return _PromotionInfo(
            nextLevel: EducationLevel.high,
            nextGrade: 1,
            levelChanged: true,
          );
        }
        return _PromotionInfo(
          nextLevel: s.educationLevel,
          nextGrade: grade + 1,
          levelChanged: false,
        );
      case EducationLevel.high:
        final maxHigh = _maxGradeFor(EducationLevel.high);
        final next = grade < maxHigh ? grade + 1 : maxHigh;
        return _PromotionInfo(
          nextLevel: s.educationLevel,
          nextGrade: next,
          levelChanged: false,
        );
    }
  }

  String _appendSchoolTag(String? memo, String prevSchool) {
    final trimmed = prevSchool.trim();
    if (trimmed.isEmpty) return memo ?? '';
    final tag = '#전학교:$trimmed';
    if (memo != null && memo.contains(tag)) return memo;
    if (memo == null || memo.trim().isEmpty) return tag;
    return '${memo.trim()}\n$tag';
  }

  List<StudentWithInfo> _transitionStudents(List<StudentWithInfo> scope) {
    return scope.where((s) => _promotionInfo(s.student).levelChanged).toList();
  }

  Future<void> _applyPromotion() async {
    if (_saving) return;
    final scopeStudents = _scopeStudents();
    if (scopeStudents.isEmpty) return;
    setState(() => _saving = true);
    try {
      for (final s in scopeStudents) {
        final info = _promotionInfo(s.student);
        String nextSchool = s.student.school;
        String? nextMemo = s.basicInfo.memo;
        if (info.levelChanged) {
          final entered = (_newSchoolByStudentId[s.student.id] ?? '').trim();
          if (entered.isNotEmpty && entered != s.student.school) {
            if (s.student.school.trim().isNotEmpty) {
              nextMemo = _appendSchoolTag(nextMemo, s.student.school);
            }
            nextSchool = entered;
          }
        }
        final updatedStudent = s.student.copyWith(
          educationLevel: info.nextLevel,
          grade: info.nextGrade,
          school: nextSchool,
        );
        final updatedBasic = s.basicInfo.copyWith(memo: nextMemo);
        await DataManager.instance.updateStudent(updatedStudent, updatedBasic);
      }
      await _clearDraft();
      if (!mounted) return;
      showAppSnackBar(context, '승급 처리가 완료되었습니다.', useRoot: true);
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, '승급 처리 실패: $e', useRoot: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildScopeSelector() {
    return Row(
      children: [
        const Text(
          '범위',
          style: TextStyle(color: kDlgText, fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 16),
        PillTabSelector(
          width: 220,
          height: 40,
          fontSize: 14,
          selectedIndex: _useCustomScope ? 1 : 0,
          tabs: const ['전체', '세부선택'],
          onTabSelected: (idx) {
            setState(() => _useCustomScope = idx == 1);
          },
        ),
        const Spacer(),
        Text(
          '대상 ${_scopeStudents().length}명',
          style: const TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  Widget _buildGradeSelection() {
    final options = _gradeOptions();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const YggDialogSectionHeader(icon: Icons.school_outlined, title: '학년 선택'),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: options.map((opt) {
            final key = _gradeKey(opt.level, opt.grade);
            final selected = _selectedGradeKeys.contains(key);
            return InkWell(
              onTap: () {
                setState(() {
                  if (selected) {
                    _selectedGradeKeys.remove(key);
                  } else {
                    _selectedGradeKeys.add(key);
                  }
                });
              },
              borderRadius: BorderRadius.circular(999),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selectedGradeKeys.add(key);
                        } else {
                          _selectedGradeKeys.remove(key);
                        }
                      });
                    },
                    activeColor: kDlgAccent,
                  ),
                  Text(
                    opt.label,
                    style: const TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildStudentSelection() {
    final students = List<StudentWithInfo>.from(widget.students)
      ..sort((a, b) => a.student.name.compareTo(b.student.name));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const YggDialogSectionHeader(icon: Icons.person_outline, title: '학생 선택'),
        Container(
          decoration: BoxDecoration(
            color: kDlgPanelBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kDlgBorder),
          ),
          height: 200,
          child: Scrollbar(
            child: ListView.builder(
              itemCount: students.length,
              itemBuilder: (context, index) {
                final s = students[index];
                final selected = _selectedStudentIds.contains(s.student.id);
                return CheckboxListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  value: selected,
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        _selectedStudentIds.add(s.student.id);
                      } else {
                        _selectedStudentIds.remove(s.student.id);
                      }
                    });
                  },
                  title: Text(
                    s.student.name,
                    style: const TextStyle(color: kDlgText),
                  ),
                  subtitle: Text(
                    '${_gradeLabel(s.student.educationLevel, s.student.grade)} · ${s.student.school.isEmpty ? '학교 미입력' : s.student.school}',
                    style: const TextStyle(color: kDlgTextSub),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: kDlgAccent,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTransitionList(List<StudentWithInfo> scopeStudents) {
    final transitions = _transitionStudents(scopeStudents);
    for (final s in transitions) {
      _schoolControllerFor(
        s.student.id,
        _newSchoolByStudentId[s.student.id] ?? '',
      );
    }
    final int enteredCount = transitions
        .where((s) => _enteredSchoolFor(s.student.id).trim().isNotEmpty)
        .length;
    final int totalCount = transitions.length;
    final List<StudentWithInfo> ordered = List<StudentWithInfo>.from(transitions)
      ..sort((a, b) {
        final aEntered = _enteredSchoolFor(a.student.id).trim().isNotEmpty;
        final bEntered = _enteredSchoolFor(b.student.id).trim().isNotEmpty;
        if (aEntered != bEntered) return aEntered ? 1 : -1;
        return a.student.name.compareTo(b.student.name);
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const YggDialogSectionHeader(icon: Icons.swap_vert, title: '과정 변경 대상'),
        if (transitions.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              color: kDlgPanelBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kDlgBorder),
            ),
            child: const Center(
              child: Text('과정 변경 대상이 없습니다.', style: TextStyle(color: kDlgTextSub)),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '입력 $enteredCount/$totalCount',
                  style: const TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: kDlgPanelBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kDlgBorder),
              ),
              child: ListView.separated(
                itemCount: ordered.length,
                separatorBuilder: (_, __) => const Divider(color: kDlgBorder, height: 1),
                itemBuilder: (context, index) {
                  final s = ordered[index];
                  final info = _promotionInfo(s.student);
                  final controller = _schoolControllerFor(
                    s.student.id,
                    _newSchoolByStudentId[s.student.id] ?? '',
                  );
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${s.student.name} · ${_gradeLabel(s.student.educationLevel, s.student.grade)} → ${_gradeLabel(info.nextLevel, info.nextGrade)}',
                                style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '현재 학교: ${s.student.school.isEmpty ? '미입력' : s.student.school}',
                                style: const TextStyle(color: kDlgTextSub),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 220,
                          child: TextField(
                            controller: controller,
                            style: const TextStyle(color: kDlgText),
                            decoration: InputDecoration(
                              labelText: '새 학교명',
                              labelStyle: const TextStyle(color: kDlgTextSub),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              filled: true,
                              fillColor: kDlgFieldBg,
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: kDlgBorder),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: kDlgAccent),
                              ),
                            ),
                            onChanged: (value) {
                              setState(() {
                                _newSchoolByStudentId[s.student.id] = value;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingDraft) {
      return const Center(child: CircularProgressIndicator());
    }

    final scopeStudents = _scopeStudents();
    final canPromote = !_saving && scopeStudents.isNotEmpty;

    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kDlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        '학년 올리기',
        style: TextStyle(color: kDlgText, fontSize: 20, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 630,
        height: 640,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(color: kDlgBorder, height: 1),
            const SizedBox(height: 12),
            _buildScopeSelector(),
            const SizedBox(height: 16),
            if (_useCustomScope) ...[
              _buildGradeSelection(),
              const SizedBox(height: 14),
              _buildStudentSelection(),
              const SizedBox(height: 14),
            ],
            Expanded(child: _buildTransitionList(scopeStudents)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await _saveDraft();
            if (!mounted) return;
            Navigator.of(context).pop(false);
          },
          style: TextButton.styleFrom(
            foregroundColor: kDlgTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          ),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: canPromote ? _applyPromotion : null,
          style: FilledButton.styleFrom(
            backgroundColor: kDlgAccent,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(
            _saving ? '승급 중...' : '승급',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

class _GradeOption {
  final EducationLevel level;
  final int grade;
  final String label;
  const _GradeOption(this.level, this.grade, this.label);
}

class _PromotionInfo {
  final EducationLevel nextLevel;
  final int nextGrade;
  final bool levelChanged;
  const _PromotionInfo({
    required this.nextLevel,
    required this.nextGrade,
    required this.levelChanged,
  });
}
