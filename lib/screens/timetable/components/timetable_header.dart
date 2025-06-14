import 'package:flutter/material.dart';
import '../../../models/class_info.dart';
import '../../../models/student.dart';
import '../../../widgets/student_registration_dialog.dart';
import '../timetable_screen.dart';  // TimetableViewType enum을 가져오기 위한 import

class TimetableHeader extends StatelessWidget {
  final TimetableViewType viewType;
  final List<ClassInfo> classes;
  final Function(TimetableViewType) onViewTypeChanged;

  const TimetableHeader({
    super.key,
    required this.viewType,
    required this.classes,
    required this.onViewTypeChanged,
  });

  void _showRegistrationDialog(BuildContext context, String type) {
    if (type == '학생') {
      showDialog(
        context: context,
        builder: (context) => StudentRegistrationDialog(
          classes: classes,
        ),
      );
    } else {
      // TODO: Show class registration dialog for the selected class
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        const Center(
          child: Text(
            '시간표',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 30),
        Row(
          children: [
            // Left Section - Split Button
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6750A4),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Edit Button
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _showRegistrationDialog(context, '학생'),
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(20),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            height: 40,
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.edit_outlined,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Edit',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Divider
                      Container(
                        width: 1,
                        height: 24,
                        color: Colors.white24,
                      ),
                      // Dropdown Button
                      Material(
                        color: Colors.transparent,
                        child: PopupMenuButton<String>(
                          padding: EdgeInsets.zero,
                          position: PopupMenuPosition.under,
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: '학생',
                              child: Text('학생'),
                            ),
                            const PopupMenuDivider(),
                            ...classes.map(
                              (classInfo) => PopupMenuItem(
                                value: classInfo.name,
                                child: Text(classInfo.name),
                              ),
                            ),
                          ],
                          onSelected: (value) => _showRegistrationDialog(context, value),
                          child: Container(
                            width: 40,
                            height: 40,
                            padding: const EdgeInsets.all(8),
                            child: const Icon(
                              Icons.arrow_drop_down,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Center Section - Segmented Button
            Expanded(
              flex: 2,
              child: Center(
                child: SizedBox(
                  width: 400,
                  child: SegmentedButton<TimetableViewType>(
                    segments: const [
                      ButtonSegment<TimetableViewType>(
                        value: TimetableViewType.classes,
                        label: Text('수업'),
                      ),
                      ButtonSegment<TimetableViewType>(
                        value: TimetableViewType.classrooms,
                        label: Text('클래스'),
                      ),
                      ButtonSegment<TimetableViewType>(
                        value: TimetableViewType.makeup,
                        label: Text('보강'),
                      ),
                      ButtonSegment<TimetableViewType>(
                        value: TimetableViewType.schedule,
                        label: Text('스케줄'),
                      ),
                    ],
                    selected: {viewType},
                    onSelectionChanged: (Set<TimetableViewType> newSelection) {
                      onViewTypeChanged(newSelection.first);
                    },
                    style: ButtonStyle(
                      backgroundColor: MaterialStateProperty.resolveWith<Color>(
                        (Set<MaterialState> states) {
                          if (states.contains(MaterialState.selected)) {
                            return const Color(0xFF78909C);
                          }
                          return Colors.transparent;
                        },
                      ),
                      foregroundColor: MaterialStateProperty.resolveWith<Color>(
                        (Set<MaterialState> states) {
                          if (states.contains(MaterialState.selected)) {
                            return Colors.white;
                          }
                          return Colors.white70;
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Right Section - Empty space to match the left section
            const Expanded(child: SizedBox()),
          ],
        ),
      ],
    );
  }
} 