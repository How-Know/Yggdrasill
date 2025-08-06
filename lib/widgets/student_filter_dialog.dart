import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import '../models/education_level.dart';
import '../services/data_manager.dart';

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
    final schools = students.map((s) => s.student.school).toSet().toList();
    final groupNames = groups.map((g) => g.name).toList();

    // 스타일 정의
    const chipBorderColor = Color(0xFFB0B0B0);
    const chipSelectedBg = Color(0xFF353545);
    const chipUnselectedBg = Color(0xFF1F1F1F);
    const chipLabelStyle = TextStyle(
      color: chipBorderColor, 
      fontWeight: FontWeight.w500, 
      fontSize: 15,
    );
    final chipShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));

    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      contentPadding: const EdgeInsets.fromLTRB(32, 28, 32, 16),
      title: const Text(
        'filter', 
        style: TextStyle(
          color: Color(0xFFB0B0B0), 
          fontSize: 22, 
          fontWeight: FontWeight.bold, 
          letterSpacing: 0.5,
        ),
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 학년별 chips
              Row(
                children: [
                  Icon(Icons.school_outlined, color: chipBorderColor, size: 20),
                  const SizedBox(width: 6),
                  Text(
                    '학년별', 
                    style: TextStyle(
                      color: Color(0xFFB0B0B0), 
                      fontSize: 16, 
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8, 
                runSpacing: 8,
                children: [
                  ...educationLevels.map((level) => FilterChip(
                    label: Text(level, style: chipLabelStyle),
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
                    backgroundColor: chipUnselectedBg,
                    selectedColor: chipSelectedBg,
                    side: BorderSide(color: chipBorderColor, width: 1.2),
                    shape: chipShape,
                    showCheckmark: true,
                    checkmarkColor: chipBorderColor,
                  )),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8, 
                runSpacing: 8,
                children: [
                  ...grades.map((grade) => FilterChip(
                    label: Text(grade, style: chipLabelStyle),
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
                    backgroundColor: chipUnselectedBg,
                    selectedColor: chipSelectedBg,
                    side: BorderSide(color: chipBorderColor, width: 1.2),
                    shape: chipShape,
                    showCheckmark: true,
                    checkmarkColor: chipBorderColor,
                  )),
                ],
              ),
              const SizedBox(height: 18),
              
              // 학교 chips
              Row(
                children: [
                  Icon(Icons.location_city_outlined, color: chipBorderColor, size: 20),
                  const SizedBox(width: 6),
                  Text(
                    '학교', 
                    style: TextStyle(
                      color: Color(0xFFB0B0B0), 
                      fontSize: 16, 
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8, 
                runSpacing: 8,
                children: [
                  ...schools.map((school) => FilterChip(
                    label: Text(school, style: chipLabelStyle),
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
                    backgroundColor: chipUnselectedBg,
                    selectedColor: chipSelectedBg,
                    side: BorderSide(color: chipBorderColor, width: 1.2),
                    shape: chipShape,
                    showCheckmark: true,
                    checkmarkColor: chipBorderColor,
                  )),
                ],
              ),
              const SizedBox(height: 18),
              
              // 그룹 chips
              Row(
                children: [
                  Icon(Icons.groups_2_outlined, color: chipBorderColor, size: 20),
                  const SizedBox(width: 6),
                  Text(
                    '그룹', 
                    style: TextStyle(
                      color: Color(0xFFB0B0B0), 
                      fontSize: 16, 
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8, 
                runSpacing: 8,
                children: [
                  ...groupNames.map((group) => FilterChip(
                    label: Text(group, style: chipLabelStyle),
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
                    backgroundColor: chipUnselectedBg,
                    selectedColor: chipSelectedBg,
                    side: BorderSide(color: chipBorderColor, width: 1.2),
                    shape: chipShape,
                    showCheckmark: true,
                    checkmarkColor: chipBorderColor,
                  )),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('취소', style: TextStyle(color: Color(0xFFB0B0B0))),
        ),
        FilledButton(
          onPressed: () {
            // 빈 필터는 null로 반환
            final hasAnyFilter = _selectedEducationLevels.isNotEmpty ||
                _selectedGrades.isNotEmpty ||
                _selectedSchools.isNotEmpty ||
                _selectedGroups.isNotEmpty;
            
            if (!hasAnyFilter) {
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
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('적용', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}