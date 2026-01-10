import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;
import '../models/student.dart';
import '../models/group_info.dart';
// removed student_details_dialog
import 'student_registration_dialog.dart';
import 'app_snackbar.dart';
import '../services/data_manager.dart';
import '../main.dart';
import '../screens/student/student_profile_page.dart';
import '../screens/student/student_course_detail_screen.dart';
import 'dark_panel_route.dart';

class StudentCard extends StatelessWidget {
  final StudentWithInfo studentWithInfo;
  final VoidCallback? onTap;
  final Function(StudentWithInfo) onShowDetails;
  final Function(StudentWithInfo)? onDelete;
  final Function(StudentWithInfo)? onUpdate;
  final bool showCheckbox;
  final bool checked;
  final void Function(bool?)? onCheckboxChanged;
  final bool enableLongPressDrag;
  final bool disableTapInteractions;
  // 더블클릭 시 학생 페이지(또는 상위에서 정의한 진입 동작)로 이동
  final Function(StudentWithInfo)? onOpenStudentPage;

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
    this.enableLongPressDrag = true,
    this.disableTapInteractions = false,
    this.onOpenStudentPage,
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

  void _showDetails(BuildContext context) {}

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
      enableLongPressDrag: enableLongPressDrag,
      disableTapInteractions: disableTapInteractions,
      onOpenStudentPage: onOpenStudentPage,
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
  final bool enableLongPressDrag;
  final bool disableTapInteractions;
  final Function(StudentWithInfo)? onOpenStudentPage;

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
    this.enableLongPressDrag = true,
    this.disableTapInteractions = false,
    this.onOpenStudentPage,
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
      try {
        await DataManager.instance.deleteStudent(widget.studentWithInfo.student.id);
        if (!context.mounted) return;
        showAppSnackBar(context, '학생이 삭제되었습니다.', useRoot: true);
      } catch (e) {
        if (!context.mounted) return;
        print('[ERROR][StudentCard] 학생 삭제 실패: $e');
        showAppSnackBar(context, '학생 삭제 실패: $e', useRoot: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final student = widget.studentWithInfo.student;
    final cardCoreInner = Card(
      color: const Color(0xFF15171C),
      margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 4.0),
      elevation: 6,
      shadowColor: Colors.black.withOpacity(0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10.0),
      ),
      child: AnimatedContainer(
          width: widget.showCheckbox ? 135 : 100,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          height: 50,
          onEnd: _onAnimEnd,
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: SizedBox(
            width: double.infinity,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (student.groupInfo != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 5,
                      height: 26,
                      decoration: BoxDecoration(
                        color: student.groupInfo!.color,
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.only(left: 12, right: widget.showCheckbox ? 32 : 12),
                  child: Text(
                    student.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFEAF2F2),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
                if (_showRealCheckbox)
                  Align(
                    alignment: Alignment.centerRight,
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

    // 우클릭 컨텍스트 메뉴: 카드 래퍼에 GestureDetector 부여 + 호버 시 손가락 커서
    Widget cardCore = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onTap: widget.disableTapInteractions ? null : () {
        final s = widget.studentWithInfo.student;
        print('[DEBUG][StudentCard] onTap(좌클릭) fired: id=' + s.id + ', name=' + s.name);
        widget.onShowDetails(widget.studentWithInfo);
      },
      onDoubleTap: widget.disableTapInteractions
          ? null
          : () {
              final s = widget.studentWithInfo.student;
              print('[DEBUG][StudentCard] onDoubleTap(더블클릭) fired: id=' + s.id + ', name=' + s.name + ', hasOpenCb=' + (widget.onOpenStudentPage != null).toString());
              if (widget.onOpenStudentPage != null) {
                widget.onOpenStudentPage!(widget.studentWithInfo);
              }
            },
      child: cardCoreInner,
    ),
    );

    if (!widget.enableLongPressDrag) {
      return cardCore;
    }

    // 데스크톱(마우스)에서는 "클릭+이동" 즉시 드래그로, 모바일/터치에서는 롱프레스 드래그로 유지.
    final bool useImmediateDrag = kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;

    final feedbackWidget = Material(
      color: Colors.transparent,
      child: Opacity(
        opacity: 0.9,
        child: SizedBox(
          width: widget.showCheckbox ? 135 : 100,
          height: 50,
          child: Card(
            color: const Color(0xFF1F1F1F),
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.0),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (student.groupInfo != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 5,
                        height: 26,
                        decoration: BoxDecoration(
                          color: student.groupInfo!.color,
                          borderRadius: BorderRadius.circular(2.5),
                        ),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text(''),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      student.name,
                      textAlign: TextAlign.center,
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
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (useImmediateDrag) {
      return Draggable<StudentWithInfo>(
        data: widget.studentWithInfo,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        maxSimultaneousDrags: 1,
        feedback: feedbackWidget,
        childWhenDragging: Opacity(opacity: 0.3, child: cardCore),
        child: cardCore,
      );
    }

    return LongPressDraggable<StudentWithInfo>(
      data: widget.studentWithInfo,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: 1,
      hapticFeedbackOnStart: true,
      feedback: feedbackWidget,
      childWhenDragging: Opacity(opacity: 0.3, child: cardCore),
      child: cardCore,
    );
  }
} 

class _ArrowPopupShape extends ShapeBorder {
  final double radius;
  final double arrowSize;
  final double arrowOffset;
  final Color borderColor;

  const _ArrowPopupShape({
    this.radius = 10,
    this.arrowSize = 10,
    this.arrowOffset = 24,
    this.borderColor = const Color(0xFF3A3F44),
  });

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final r = Radius.circular(radius);
    final arrowHeight = arrowSize;
    final arrowWidth = arrowSize * 1.2;
    final double arrowX = (rect.width / 2).clamp(arrowOffset, rect.width - arrowOffset);
    final Path path = Path()
      ..moveTo(rect.left + r.x, rect.top + arrowHeight)
      ..lineTo(rect.left + arrowX - arrowWidth / 2, rect.top + arrowHeight)
      ..lineTo(rect.left + arrowX, rect.top)
      ..lineTo(rect.left + arrowX + arrowWidth / 2, rect.top + arrowHeight)
      ..lineTo(rect.right - r.x, rect.top + arrowHeight)
      ..arcToPoint(Offset(rect.right, rect.top + arrowHeight + r.y), radius: r)
      ..lineTo(rect.right, rect.bottom - r.y)
      ..arcToPoint(Offset(rect.right - r.x, rect.bottom), radius: r)
      ..lineTo(rect.left + r.x, rect.bottom)
      ..arcToPoint(Offset(rect.left, rect.bottom - r.y), radius: r)
      ..lineTo(rect.left, rect.top + arrowHeight + r.y)
      ..arcToPoint(Offset(rect.left + r.x, rect.top + arrowHeight), radius: r)
      ..close();
    return path;
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = borderColor;
    canvas.drawPath(getOuterPath(rect), paint);
  }

  @override
  ShapeBorder scale(double t) => this;
} 