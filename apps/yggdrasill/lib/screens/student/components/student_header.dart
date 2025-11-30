import 'package:flutter/material.dart';
import '../../../models/student.dart';
import 'package:mneme_flutter/models/student_view_type.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

class StudentHeader extends StatefulWidget {
  final StudentViewType viewType;
  final Function(StudentViewType) onViewTypeChanged;
  final Function(String) onSearch;
  final VoidCallback onAddStudent;

  const StudentHeader({
    Key? key,
    required this.viewType,
    required this.onViewTypeChanged,
    required this.onSearch,
    required this.onAddStudent,
  }) : super(key: key);

  @override
  State<StudentHeader> createState() => _StudentHeaderState();
}

class _StudentHeaderState extends State<StudentHeader> {
  late TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = ImeAwareTextEditingController();
    _searchController.addListener(() {
      widget.onSearch(_searchController.text);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          SegmentedButton<StudentViewType>(
            segments: const [
              ButtonSegment(
                value: StudentViewType.all,
                label: Text('전체'),
              ),
              ButtonSegment(
                value: StudentViewType.byClass,
                label: Text('반별'),
              ),
              ButtonSegment(
                value: StudentViewType.bySchool,
                label: Text('학교별'),
              ),
              ButtonSegment(
                value: StudentViewType.byDate,
                label: Text('등록일'),
              ),
            ],
            selected: {widget.viewType},
            onSelectionChanged: (Set<StudentViewType> newSelection) {
              widget.onViewTypeChanged(newSelection.first);
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: '학생 검색...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 16),
          FilledButton.icon(
            onPressed: widget.onAddStudent,
            icon: const Icon(Icons.add),
            label: const Text('학생 추가'),
          ),
        ],
      ),
    );
  }
} 

