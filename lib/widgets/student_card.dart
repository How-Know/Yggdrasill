import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import 'student_details_dialog.dart';
import 'student_registration_dialog.dart';
import '../services/data_manager.dart';

class StudentCard extends StatelessWidget {
  final StudentWithInfo studentWithInfo;
  final VoidCallback? onTap;
  final Function(StudentWithInfo) onShowDetails;
  final Function(StudentWithInfo)? onDelete;
  final Function(StudentWithInfo)? onUpdate;
  final bool showCheckbox;
  final bool checked;
  final void Function(bool?)? onCheckboxChanged;

  const StudentCard({
    Key? key,
    required this.studentWithInfo,
    this.onTap,
    required this.onShowDetails,
    this.onDelete,
    this.onUpdate,
    this.showCheckbox = false,
    this.checked = false,
    this.onCheckboxChanged,
  }) : super(key: key);

  Future<void> _handleEdit(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (context) => StudentRegistrationDialog(
        student: studentWithInfo.student,
        onSave: (updatedStudent, basicInfo) async {
          await DataManager.instance.updateStudent(updatedStudent, basicInfo);
          Navigator.of(context).pop();
        },
        groups: DataManager.instance.groups,
      ),
    );
  }

  void _showDetails(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => StudentDetailsDialog(studentWithInfo: studentWithInfo),
    );
  }

  Future<void> _handleDelete(BuildContext context) async {
    print('[DEBUG][StudentCard] _handleDelete 진입: id=${studentWithInfo.student.id}, name=${studentWithInfo.student.name}');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text(
          '학생 삭제',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          '정말로 이 학생을 삭제하시겠습니까?',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    print('[DEBUG][StudentCard] _handleDelete 다이얼로그 결과: confirmed=$confirmed');
    if (confirmed == true) {
      print('[DEBUG][StudentCard] onDelete 콜백 호출 직전');
      if (onDelete != null) {
        onDelete!(studentWithInfo);
        print('[DEBUG][StudentCard] onDelete 콜백 호출 완료');
      } else {
        print('[DEBUG][StudentCard] onDelete 콜백이 null');
      }
    }
  }

  void _showMenu(BuildContext context) {
    final RenderBox button = context.findRenderObject() as RenderBox;
    final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset(button.size.width - 40, 0), ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    showMenu(
      context: context,
      color: const Color(0xFF2A2A2A),
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        PopupMenuItem(
          child: ListTile(
            leading: const Icon(Icons.edit_outlined, color: Colors.white70),
            title: const Text(
              '수정',
              style: TextStyle(color: Colors.white),
            ),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onTap: () {
              Navigator.of(context).pop();
              _handleEdit(context);
            },
          ),
        ),
        PopupMenuItem(
          child: ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text(
              '삭제',
              style: TextStyle(color: Colors.red),
            ),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onTap: () {
              Navigator.of(context).pop();
              _handleDelete(context);
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final student = studentWithInfo.student;
    return _StudentCardWithCheckboxDelay(
      studentWithInfo: studentWithInfo,
      onTap: onTap,
      onShowDetails: onShowDetails,
      onDelete: onDelete,
      onUpdate: onUpdate,
      showCheckbox: showCheckbox,
      checked: checked,
      onCheckboxChanged: onCheckboxChanged,
    );
  }
}

class _StudentCardWithCheckboxDelay extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  final VoidCallback? onTap;
  final Function(StudentWithInfo) onShowDetails;
  final Function(StudentWithInfo)? onDelete;
  final Function(StudentWithInfo)? onUpdate;
  final bool showCheckbox;
  final bool checked;
  final void Function(bool?)? onCheckboxChanged;

  const _StudentCardWithCheckboxDelay({
    Key? key,
    required this.studentWithInfo,
    this.onTap,
    required this.onShowDetails,
    this.onDelete,
    this.onUpdate,
    this.showCheckbox = false,
    this.checked = false,
    this.onCheckboxChanged,
  }) : super(key: key);

  @override
  State<_StudentCardWithCheckboxDelay> createState() => _StudentCardWithCheckboxDelayState();
}

class _StudentCardWithCheckboxDelayState extends State<_StudentCardWithCheckboxDelay> {
  bool _showRealCheckbox = false;
  bool _prevShowCheckbox = false;

  @override
  void didUpdateWidget(covariant _StudentCardWithCheckboxDelay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showCheckbox != oldWidget.showCheckbox) {
      if (widget.showCheckbox) {
        // 애니메이션이 끝난 후에 체크박스 표시
        setState(() {
          _showRealCheckbox = false;
        });
      } else {
        setState(() {
          _showRealCheckbox = false;
        });
      }
    }
  }

  void _onAnimEnd() {
    if (widget.showCheckbox) {
      setState(() {
        _showRealCheckbox = true;
      });
    }
  }

  Future<void> _handleDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('학생 삭제', style: TextStyle(color: Colors.white)),
        content: const Text('정말로 이 학생을 삭제하시겠습니까?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('삭제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DataManager.instance.deleteStudent(widget.studentWithInfo.student.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final student = widget.studentWithInfo.student;
    return Card(
      color: const Color(0xFF1F1F1F),
      margin: const EdgeInsets.symmetric(vertical: 2.0, horizontal: 4.0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: AnimatedContainer(
        width: widget.showCheckbox ? 147 : 115,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        height: 50,
        onEnd: _onAnimEnd,
        padding: EdgeInsets.only(
          left: student.groupInfo == null ? 15.0 : 8.0,
          right: 4.0,
        ),
        child: SizedBox(
          width: widget.showCheckbox ? 147 : 125,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              if (student.groupInfo != null) ...[
                Container(
                  width: 5,
                  height: 26,
                  decoration: BoxDecoration(
                    color: student.groupInfo!.color,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(
                  student.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white54, size: 20),
                color: const Color(0xFF2A2A2A),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                tooltip: '',
                onSelected: (value) async {
                  if (value == 'edit') {
                    if (widget.onUpdate != null) {
                      widget.onUpdate!(widget.studentWithInfo);
                    }
                  } else if (value == 'delete') {
                    await _handleDelete(context);
                  } else if (value == 'details') {
                    widget.onShowDetails(widget.studentWithInfo);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'details',
                    child: ListTile(
                      leading: const Icon(Icons.info_outline, color: Colors.white70),
                      title: const Text('상세보기', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      leading: const Icon(Icons.edit_outlined, color: Colors.white70),
                      title: const Text('수정', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: const Icon(Icons.delete_outline, color: Colors.red),
                      title: const Text('삭제', style: TextStyle(color: Colors.red)),
                    ),
                  ),
                ],
              ),
              if (_showRealCheckbox)
                Padding(
                  padding: const EdgeInsets.only(left: 0.0),
                  child: Checkbox(
                    value: widget.checked,
                    onChanged: widget.onCheckboxChanged,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    side: BorderSide(color: Colors.grey.shade500, width: 1.2),
                    fillColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.selected) ? Colors.blue.shade400 : Colors.grey.shade200),
                    checkColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
} 