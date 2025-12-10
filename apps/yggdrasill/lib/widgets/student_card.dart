import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/group_info.dart';
// removed student_details_dialog
import 'student_registration_dialog.dart';
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
            onTap: () async {
              print('[DEBUG][StudentCard] 수정 메뉴 탭');
              Navigator.of(context).pop();
              await Future.delayed(const Duration(milliseconds: 0));
              print('[DEBUG][StudentCard] 수정 다이얼로그 호출 직전');
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
            onTap: () async {
              print('[DEBUG][StudentCard] 삭제 메뉴 탭');
              Navigator.of(context).pop();
              await Future.delayed(const Duration(milliseconds: 0));
              print('[DEBUG][StudentCard] 삭제 다이얼로그 호출 직전');
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
  Offset? _tapDownPosition;

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
      onSecondaryTapUp: (details) async {
        if (widget.disableTapInteractions) return;
        final s = widget.studentWithInfo.student;
        print('[DEBUG][StudentCard] onSecondaryTapUp(우클릭) fired: id=' + s.id + ', name=' + s.name + ', pos=' + details.globalPosition.toString());
        final overlayBox = Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
        if (overlayBox == null) return;
        final pos = details.globalPosition;
        final position = RelativeRect.fromLTRB(
          pos.dx,
          pos.dy,
          overlayBox.size.width - pos.dx,
          overlayBox.size.height - pos.dy,
        );
        final selected = await showMenu<String>(
          context: context,
          color: const Color(0xFF2A2A2A), // 학생 추가 버튼 드롭다운 톤
          position: position,
          constraints: const BoxConstraints(minWidth: 132), // 절반 너비로 축소
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF3A3F44)),
          ),
          elevation: 10,
          items: const [
            PopupMenuItem(
              value: 'details',
              child: ListTile(
                leading: Icon(Icons.info_outline, color: Colors.white70),
                title: Text('상세보기', style: TextStyle(color: Colors.white)),
              ),
            ),
            PopupMenuItem(
              value: 'edit',
              child: ListTile(
                leading: Icon(Icons.edit_outlined, color: Colors.white70),
                title: Text('수정', style: TextStyle(color: Colors.white)),
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red),
                title: Text('삭제', style: TextStyle(color: Colors.red)),
              ),
            ),
          ],
        );
        print('[DEBUG][StudentCard] context menu selected=' + (selected ?? 'null') + ', id=' + s.id + ');');
        switch (selected) {
          case 'details':
            if (widget.onOpenStudentPage != null) {
              widget.onOpenStudentPage!(widget.studentWithInfo);
            } else {
              Navigator.of(context).push(
                DarkPanelRoute(
                  child: StudentCourseDetailScreen(studentWithInfo: widget.studentWithInfo),
                ),
              );
            }
            break;
          case 'edit':
            if (widget.onUpdate != null) {
              widget.onUpdate!(widget.studentWithInfo);
            } else {
              final dialogContext = rootNavigatorKey.currentContext ?? context;
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                try {
                  await showDialog(
                    context: dialogContext,
                    builder: (context) => StudentRegistrationDialog(
                      student: widget.studentWithInfo.student,
                      onSave: (updatedStudent, basicInfo) async {
                        await DataManager.instance.updateStudent(updatedStudent, basicInfo);
                        Navigator.of(context).pop();
                      },
                      groups: DataManager.instance.groups,
                    ),
                  );
                } catch (e, st) {
                  print('[ERROR][StudentCard] edit dialog 예외: ' + e.toString() + '\n' + st.toString());
                }
              });
            }
            break;
          case 'delete':
            if (widget.onDelete != null) {
              widget.onDelete!(widget.studentWithInfo);
            } else {
              final dialogContext = rootNavigatorKey.currentContext ?? context;
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                try {
                  await _handleDelete(dialogContext);
                } catch (e, st) {
                  print('[ERROR][StudentCard] delete dialog 예외: ' + e.toString() + '\n' + st.toString());
                }
              });
            }
            break;
          default:
            break;
        }
      },
      child: cardCoreInner,
    ),
    );

    if (!widget.enableLongPressDrag) {
      return cardCore;
    }

    return LongPressDraggable<StudentWithInfo>(
      data: widget.studentWithInfo,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      hapticFeedbackOnStart: true,
      feedback: Material(
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
                      child: Text(
                        '',
                      ),
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
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: cardCore,
      ),
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