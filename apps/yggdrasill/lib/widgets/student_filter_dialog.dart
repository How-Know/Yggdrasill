import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import '../models/education_level.dart';
import '../services/data_manager.dart';
import 'dialog_tokens.dart';

class StudentFilterDialog extends StatefulWidget {
  final Map<String, Set<String>>? initialFilter;
  
  const StudentFilterDialog({
    Key? key,
    this.initialFilter,
  }) : super(key: key);

  @override
  State<StudentFilterDialog> createState() => _StudentFilterDialogState();
}

class _StudentFilterDialogState extends State<StudentFilterDialog> {
  Set<String> _selectedEducationLevels = {};
  Set<String> _selectedGrades = {};
  Set<String> _selectedSchools = {};
  Set<String> _selectedGroups = {};

  bool get _hasAnySelection =>
      _selectedEducationLevels.isNotEmpty ||
      _selectedGrades.isNotEmpty ||
      _selectedSchools.isNotEmpty ||
      _selectedGroups.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (widget.initialFilter != null) {
      _selectedEducationLevels = Set.from(widget.initialFilter!['educationLevels'] ?? {});
      _selectedGrades = Set.from(widget.initialFilter!['grades'] ?? {});
      _selectedSchools = Set.from(widget.initialFilter!['schools'] ?? {});
      _selectedGroups = Set.from(widget.initialFilter!['groups'] ?? {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final students = DataManager.instance.students;
    final groups = DataManager.instance.groups;
    
    // 데이터 준비
    final educationLevels = ['초등', '중등', '고등'];
    final grades = [
      '초1', '초2', '초3', '초4', '초5', '초6',
      '중1', '중2', '중3',
      '고1', '고2', '고3', 'N수',
    ];
    final schools = students
        .map((s) => s.student.school.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final groupNames = groups.map((g) => g.name.trim()).where((n) => n.isNotEmpty).toList()
      ..sort();

    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kDlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      title: const Text(
        '학생 필터',
        style: TextStyle(color: kDlgText, fontSize: 20, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Divider(color: kDlgBorder, height: 1),
              const SizedBox(height: 18),

              const YggDialogSectionHeader(icon: Icons.school_outlined, title: '학년'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...educationLevels.map((level) => YggDialogFilterChip(
                        label: level,
                        selected: _selectedEducationLevels.contains(level),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _selectedEducationLevels.add(level);
                            } else {
                              _selectedEducationLevels.remove(level);
                            }
                          });
                        },
                      )),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...grades.map((grade) => YggDialogFilterChip(
                        label: grade,
                        selected: _selectedGrades.contains(grade),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _selectedGrades.add(grade);
                            } else {
                              _selectedGrades.remove(grade);
                            }
                          });
                        },
                      )),
                ],
              ),
              const SizedBox(height: 20),

              const YggDialogSectionHeader(icon: Icons.location_city_outlined, title: '학교'),
              if (schools.isEmpty)
                const Text('등록된 학교 정보가 없습니다.',
                    style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700))
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ...schools.map((school) => YggDialogFilterChip(
                          label: school,
                          selected: _selectedSchools.contains(school),
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _selectedSchools.add(school);
                              } else {
                                _selectedSchools.remove(school);
                              }
                            });
                          },
                        )),
                  ],
                ),
              const SizedBox(height: 20),

              const YggDialogSectionHeader(icon: Icons.groups_2_outlined, title: '그룹'),
              if (groupNames.isEmpty)
                const Text('등록된 그룹이 없습니다.',
                    style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700))
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ...groupNames.map((group) => YggDialogFilterChip(
                          label: group,
                          selected: _selectedGroups.contains(group),
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _selectedGroups.add(group);
                              } else {
                                _selectedGroups.remove(group);
                              }
                            });
                          },
                        )),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _hasAnySelection
              ? () {
                  setState(() {
                    _selectedEducationLevels.clear();
                    _selectedGrades.clear();
                    _selectedSchools.clear();
                    _selectedGroups.clear();
                  });
                }
              : null,
          style: TextButton.styleFrom(
            foregroundColor: kDlgTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          ),
          child: const Text('초기화'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          style: TextButton.styleFrom(
            foregroundColor: kDlgTextSub,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () {
            if (!_hasAnySelection) {
              Navigator.of(context).pop(null);
              return;
            }
            final filterData = <String, Set<String>>{
              'educationLevels': Set<String>.from(_selectedEducationLevels),
              'grades': Set<String>.from(_selectedGrades),
              'schools': Set<String>.from(_selectedSchools),
              'groups': Set<String>.from(_selectedGroups),
            };
            Navigator.of(context).pop(filterData);
          },
          style: FilledButton.styleFrom(
            backgroundColor: kDlgAccent,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('적용',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }
}