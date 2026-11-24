import 'package:flutter/material.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

import '../../models/attendance_record.dart';
import '../../models/education_level.dart';
import '../../models/student.dart';
import '../../services/data_manager.dart';
import '../../widgets/app_dialog_action_button.dart';
import '../../widgets/dialog_tokens.dart';
import '../../widgets/shared_back_button.dart';
import '../../widgets/solid_capsule_action_bar.dart';
import '../../widgets/student_profile_avatar.dart';
import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

enum StudentLookupStatus {
  attending,
  departedToday,
  nonAttending,
}

enum _StudentLookupFilter {
  all,
  nonAttending,
  attending,
}

class StudentHomeworkLookupSheet extends StatefulWidget {
  const StudentHomeworkLookupSheet({
    super.key,
    required this.selectedStudentId,
    required this.isLoadingStudent,
    required this.pendingConfirmCount,
    required this.isConfirmSaving,
    required this.statusResolver,
    required this.onCloseSheet,
    required this.onSelectStudent,
    required this.onBackToList,
    required this.onAddHomework,
    required this.onOpenOverview,
    required this.onConfirmPending,
    required this.cardsBuilder,
  });

  final String? selectedStudentId;
  final bool isLoadingStudent;
  final int pendingConfirmCount;
  final bool isConfirmSaving;
  final StudentLookupStatus Function(String studentId) statusResolver;
  final VoidCallback onCloseSheet;
  final ValueChanged<StudentWithInfo> onSelectStudent;
  final VoidCallback onBackToList;
  final VoidCallback onAddHomework;
  final VoidCallback onOpenOverview;
  final Future<void> Function()? onConfirmPending;
  final Widget Function(BuildContext sheetContext, Student student) cardsBuilder;

  @override
  State<StudentHomeworkLookupSheet> createState() =>
      _StudentHomeworkLookupSheetState();
}

class _StudentHomeworkLookupSheetState
    extends State<StudentHomeworkLookupSheet> {
  final TextEditingController _searchCtrl = ImeAwareTextEditingController();
  final FocusNode _searchFocus = FocusNode();
  _StudentLookupFilter _filter = _StudentLookupFilter.all;
  bool _confirmBusy = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  String _gradeLabelOf(Student student) {
    final prefix = switch (student.educationLevel) {
      EducationLevel.elementary => '초',
      EducationLevel.middle => '중',
      EducationLevel.high => '고',
    };
    return '$prefix${student.grade}';
  }

  String _schoolAndGradeOf(Student student) {
    final school = student.school.trim();
    final grade = _gradeLabelOf(student);
    if (school.isEmpty) return grade;
    return '$school · $grade';
  }

  String _statusLabelOf(StudentLookupStatus status) {
    switch (status) {
      case StudentLookupStatus.attending:
        return '등원중';
      case StudentLookupStatus.departedToday:
        return '하원';
      case StudentLookupStatus.nonAttending:
        return '미등원';
    }
  }

  bool _matchesQuery(Student student, String query) {
    if (query.isEmpty) return true;
    final lower = query.toLowerCase();
    final name = student.name.trim().toLowerCase();
    final school = student.school.trim().toLowerCase();
    final grade = _gradeLabelOf(student).toLowerCase();
    final fullLevel =
        '${getEducationLevelName(student.educationLevel)}${student.grade}'
            .toLowerCase();
    return name.contains(lower) ||
        school.contains(lower) ||
        grade.contains(lower) ||
        fullLevel.contains(lower);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final panelStyle = PreviewAcademyPanelStyle.forBrightness(brightness);
    final borderColor =
        FabTabBarTokens.groupedCardBorderFor(brightness).top.color;

    return ValueListenableBuilder<List<StudentWithInfo>>(
      valueListenable: DataManager.instance.studentsNotifier,
      builder: (context, allStudents, _) {
        return ValueListenableBuilder<List<AttendanceRecord>>(
          valueListenable: DataManager.instance.attendanceRecordsNotifier,
          builder: (context, __, ___) {
            final selectedId = (widget.selectedStudentId ?? '').trim();
            StudentWithInfo? selectedRow;
            if (selectedId.isNotEmpty) {
              for (final row in allStudents) {
                if (row.student.id == selectedId) {
                  selectedRow = row;
                  break;
                }
              }
            }
            if (selectedRow != null) {
              return _buildSelectedStudentView(
                context: context,
                student: selectedRow.student,
                panelStyle: panelStyle,
                borderColor: borderColor,
                brightness: brightness,
              );
            }
            return _buildStudentListView(
              context: context,
              allStudents: allStudents,
              panelStyle: panelStyle,
              borderColor: borderColor,
              brightness: brightness,
            );
          },
        );
      },
    );
  }

  Widget _buildCloseChevronButton(PreviewAcademyPanelStyle panelStyle) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        tooltip: '닫기',
        onPressed: widget.onCloseSheet,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(),
        icon: const Icon(Icons.chevron_right_rounded, size: 26),
        color: panelStyle.label,
      ),
    );
  }

  Widget _buildStatusPill({
    required StudentLookupStatus status,
    required PreviewAcademyPanelStyle panelStyle,
    required Brightness brightness,
  }) {
    final isAttending = status == StudentLookupStatus.attending;
    final bgColor = isAttending
        ? kDlgAccent.withValues(alpha: 0.16)
        : (brightness == Brightness.light
            ? Colors.black.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.08));
    final borderColor = isAttending
        ? kDlgAccent.withValues(alpha: 0.6)
        : (brightness == Brightness.light
            ? Colors.black.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.12));
    final textColor = isAttending ? kDlgAccent : panelStyle.label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        _statusLabelOf(status),
        style: TextStyle(
          color: textColor,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }

  Widget _buildStudentListView({
    required BuildContext context,
    required List<StudentWithInfo> allStudents,
    required PreviewAcademyPanelStyle panelStyle,
    required Color borderColor,
    required Brightness brightness,
  }) {
    final query = _searchCtrl.text.trim();
    final filtered = <({StudentWithInfo row, StudentLookupStatus status})>[];
    var attendingCount = 0;
    var nonAttendingCount = 0;
    for (final row in allStudents) {
      final status = widget.statusResolver(row.student.id);
      if (status == StudentLookupStatus.attending) {
        attendingCount++;
      } else {
        nonAttendingCount++;
      }
      if (!_matchesQuery(row.student, query)) continue;
      if (_filter == _StudentLookupFilter.attending &&
          status != StudentLookupStatus.attending) {
        continue;
      }
      if (_filter == _StudentLookupFilter.nonAttending &&
          status == StudentLookupStatus.attending) {
        continue;
      }
      filtered.add((row: row, status: status));
    }
    filtered.sort((a, b) => a.row.student.name.compareTo(b.row.student.name));

    final fieldBg = brightness == Brightness.light
        ? Colors.white
        : panelStyle.dropdownBackground;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _buildCloseChevronButton(panelStyle),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '과제카드 조회',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: panelStyle.title,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '${filtered.length}명',
                style: TextStyle(
                  color: panelStyle.label,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 44,
            decoration: BoxDecoration(
              color: fieldBg,
              borderRadius: BorderRadius.circular(
                FabTabBarTokens.fabMenuPillRadius,
              ),
              border: Border.all(color: borderColor),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: panelStyle.label,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    style: TextStyle(
                      color: panelStyle.title,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '학생 이름, 학교, 학년 검색',
                      hintStyle: TextStyle(
                        color: panelStyle.label,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                if (query.isNotEmpty)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      tooltip: '지우기',
                      onPressed: _searchCtrl.clear,
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: panelStyle.label,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              YggDialogFilterChip(
                label: '전체 ${allStudents.length}',
                height: 32,
                selected: _filter == _StudentLookupFilter.all,
                onSelected: (_) =>
                    setState(() => _filter = _StudentLookupFilter.all),
              ),
              YggDialogFilterChip(
                label: '미등원·하원 $nonAttendingCount',
                height: 32,
                selected: _filter == _StudentLookupFilter.nonAttending,
                onSelected: (_) =>
                    setState(() => _filter = _StudentLookupFilter.nonAttending),
              ),
              YggDialogFilterChip(
                label: '등원중 $attendingCount',
                height: 32,
                selected: _filter == _StudentLookupFilter.attending,
                onSelected: (_) =>
                    setState(() => _filter = _StudentLookupFilter.attending),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      query.isEmpty ? '등록된 재원생이 없습니다.' : '일치하는 학생이 없습니다.',
                      style: TextStyle(
                        color: panelStyle.label,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      final student = entry.row.student;
                      final status = entry.status;
                      final isAttending =
                          status == StudentLookupStatus.attending;
                      return Material(
                        color: panelStyle.dropdownBackground,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => widget.onSelectStudent(entry.row),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isAttending
                                    ? kDlgAccent.withValues(alpha: 0.45)
                                    : borderColor,
                              ),
                            ),
                            child: Row(
                              children: [
                                StudentProfileAvatar(
                                  student: student,
                                  radius: 20,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        student.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: panelStyle.title,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _schoolAndGradeOf(student),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: panelStyle.label,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _buildStatusPill(
                                  status: status,
                                  panelStyle: panelStyle,
                                  brightness: brightness,
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  isAttending
                                      ? Icons.open_in_new_rounded
                                      : Icons.chevron_right_rounded,
                                  size: 20,
                                  color: panelStyle.label,
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
    );
  }

  Widget _buildSelectedStudentView({
    required BuildContext context,
    required Student student,
    required PreviewAcademyPanelStyle panelStyle,
    required Color borderColor,
    required Brightness brightness,
  }) {
    final status = widget.statusResolver(student.id);
    final showConfirmBar =
        widget.pendingConfirmCount > 0 || widget.isConfirmSaving;
    final canRunConfirm = widget.pendingConfirmCount > 0 &&
        !widget.isConfirmSaving &&
        !_confirmBusy &&
        widget.onConfirmPending != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Row(
            children: [
              SharedBackButton(
                tooltip: '학생 목록',
                onPressed: widget.onBackToList,
              ),
              const SizedBox(width: 12),
              StudentProfileAvatar(
                student: student,
                radius: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            student.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: panelStyle.title,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildStatusPill(
                          status: status,
                          panelStyle: panelStyle,
                          brightness: brightness,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _schoolAndGradeOf(student),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: panelStyle.label,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SolidCapsuleActionBar(
                children: [
                  SolidCapsuleActionButton(
                    tooltip: '과제 추가',
                    icon: Icons.add_rounded,
                    onPressed: widget.onAddHomework,
                  ),
                  SolidCapsuleActionButton(
                    tooltip: '과제 현황',
                    icon: Icons.assignment_rounded,
                    onPressed: widget.onOpenOverview,
                  ),
                ],
              ),
              const SizedBox(width: 4),
              _buildCloseChevronButton(panelStyle),
            ],
          ),
        ),
        Divider(height: 1, color: panelStyle.divider),
        Expanded(
          child: widget.isLoadingStudent
              ? const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: kDlgAccent,
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: 560 * 2 / 3 - 26.67,
                      child: widget.cardsBuilder(context, student),
                    ),
                  ),
                ),
        ),
        if (showConfirmBar)
          FabStyleGlassPanel(
            useFabTabBarBackground: true,
            borderRadius: BorderRadius.zero,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.isConfirmSaving
                        ? '채점 초안을 저장하고 있습니다...'
                        : '채점 대기 ${widget.pendingConfirmCount}개',
                    style: TextStyle(
                      color: panelStyle.label,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                AppDialogConfirmButton(
                  label: _confirmBusy ? '처리 중' : '완료',
                  showIcon: !_confirmBusy,
                  onPressed: !canRunConfirm
                      ? null
                      : () async {
                          final action = widget.onConfirmPending;
                          if (action == null) return;
                          setState(() => _confirmBusy = true);
                          try {
                            await action();
                          } finally {
                            if (mounted) {
                              setState(() => _confirmBusy = false);
                            }
                          }
                        },
                ),
              ],
            ),
          ),
      ],
    );
  }
}
