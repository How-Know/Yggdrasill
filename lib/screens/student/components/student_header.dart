import 'package:flutter/material.dart';
import '../../../models/student.dart';

class StudentHeader extends StatelessWidget {
  final StudentViewType viewType;
  final Function(StudentViewType) onViewTypeChanged;
  final Function() onAddStudent;
  final Function(String) onSearch;
  final TextEditingController searchController;

  const StudentHeader({
    super.key,
    required this.viewType,
    required this.onViewTypeChanged,
    required this.onAddStudent,
    required this.onSearch,
    required this.searchController,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Center(
          child: Text(
            '학생',
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
            // Left Section
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 120,
                  child: FilledButton.icon(
                    onPressed: onAddStudent,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1976D2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    icon: const Icon(Icons.add, size: 24),
                    label: const Text(
                      '등록',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Center Section - Segmented Button
            Expanded(
              flex: 2,
              child: Center(
                child: SizedBox(
                  width: 500,
                  child: SegmentedButton<StudentViewType>(
                    segments: const [
                      ButtonSegment<StudentViewType>(
                        value: StudentViewType.all,
                        label: Text('모든 학생'),
                      ),
                      ButtonSegment<StudentViewType>(
                        value: StudentViewType.byClass,
                        label: Text('클래스'),
                      ),
                      ButtonSegment<StudentViewType>(
                        value: StudentViewType.bySchool,
                        label: Text('학교별'),
                      ),
                      ButtonSegment<StudentViewType>(
                        value: StudentViewType.byDate,
                        label: Text('수강 일자'),
                      ),
                    ],
                    selected: {viewType},
                    onSelectionChanged: (Set<StudentViewType> newSelection) {
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
            // Right Section
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 240,
                  child: SearchBar(
                    controller: searchController,
                    onChanged: onSearch,
                    hintText: '학생 검색',
                    leading: const Icon(
                      Icons.search,
                      color: Colors.white70,
                    ),
                    backgroundColor: MaterialStateColor.resolveWith(
                      (states) => const Color(0xFF2A2A2A),
                    ),
                    elevation: MaterialStateProperty.all(0),
                    padding: const MaterialStatePropertyAll<EdgeInsets>(
                      EdgeInsets.symmetric(horizontal: 16.0),
                    ),
                    textStyle: const MaterialStatePropertyAll<TextStyle>(
                      TextStyle(color: Colors.white),
                    ),
                    hintStyle: MaterialStatePropertyAll<TextStyle>(
                      TextStyle(color: Colors.white.withOpacity(0.5)),
                    ),
                    side: MaterialStatePropertyAll<BorderSide>(
                      BorderSide(color: Colors.white.withOpacity(0.2)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
} 