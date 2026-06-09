import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/teacher.dart';
import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import 'dialog_tokens.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

/// 선생님 등록·수정 — [PreviewAcademyDialogSheet] 공용 스타일 사용.
class TeacherRegistrationDialog extends StatefulWidget {
  final Teacher? teacher;
  final void Function(Teacher) onSave;
  final Future<void> Function()? onDelete;

  const TeacherRegistrationDialog({
    super.key,
    this.teacher,
    required this.onSave,
    this.onDelete,
  });

  static bool isOwnerTeacher(Teacher teacher) {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      return uid != null && (teacher.userId ?? '') == uid;
    } catch (_) {
      return false;
    }
  }

  static String teacherPositionLabel(Teacher teacher) {
    return isOwnerTeacher(teacher) ? '원장' : '선생님';
  }

  static String titleFor(Teacher? teacher) {
    if (teacher == null) return '선생님 추가';
    return '${teacher.name} ${teacherPositionLabel(teacher)}';
  }

  static Future<void> show({
    required BuildContext context,
    Teacher? teacher,
    required void Function(Teacher) onSave,
    Future<void> Function()? onDelete,
  }) {
    final title = titleFor(teacher);
    return PreviewAcademyDialogRoute.show<void>(
      context: context,
      barrierLabel: title,
      builder: (context) {
        return TeacherRegistrationDialog(
          teacher: teacher,
          onSave: onSave,
          onDelete: onDelete,
        );
      },
    );
  }

  @override
  State<TeacherRegistrationDialog> createState() =>
      _TeacherRegistrationDialogState();
}

class _TeacherRegistrationDialogState extends State<TeacherRegistrationDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _contactController;
  late final TextEditingController _emailController;
  late final TextEditingController _descriptionController;
  late final FocusNode _nameFocusNode;
  late final FocusNode _contactFocusNode;
  late final FocusNode _emailFocusNode;
  late final FocusNode _descriptionFocusNode;
  final GlobalKey _roleAnchorKey = GlobalKey();

  TeacherRole _role = TeacherRole.all;
  bool _isOwnerTeacher = false;

  @override
  void initState() {
    super.initState();
    final t = widget.teacher;
    _nameController = ImeAwareTextEditingController(text: t?.name ?? '');
    _contactController = ImeAwareTextEditingController(text: t?.contact ?? '');
    _emailController = ImeAwareTextEditingController(text: t?.email ?? '');
    _descriptionController =
        ImeAwareTextEditingController(text: t?.description ?? '');
    _nameFocusNode = FocusNode();
    _contactFocusNode = FocusNode();
    _emailFocusNode = FocusNode();
    _descriptionFocusNode = FocusNode();
    _role = t?.role ?? TeacherRole.all;
    _isOwnerTeacher =
        t != null && TeacherRegistrationDialog.isOwnerTeacher(t);
    for (final c in [
      _nameController,
      _contactController,
      _emailController,
      _descriptionController,
    ]) {
      c.addListener(_onFieldChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nameFocusNode.requestFocus();
    });
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [
      _nameController,
      _contactController,
      _emailController,
      _descriptionController,
    ]) {
      c.removeListener(_onFieldChanged);
      c.dispose();
    }
    _nameFocusNode.dispose();
    _contactFocusNode.dispose();
    _emailFocusNode.dispose();
    _descriptionFocusNode.dispose();
    super.dispose();
  }

  PreviewAcademyPanelStyle _style(BuildContext context) {
    return FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
  }

  void _close() {
    Navigator.of(context).pop();
  }

  void _confirm() {
    if (_nameController.text.trim().isEmpty) return;
    final existing = widget.teacher;
    final teacher = Teacher(
      id: existing?.id,
      userId: existing?.userId,
      name: _nameController.text.trim(),
      role: _role,
      contact: _contactController.text.trim(),
      email: _emailController.text.trim(),
      description: _descriptionController.text.trim(),
      displayOrder: existing?.displayOrder,
      pinHash: existing?.pinHash,
      avatarUrl: existing?.avatarUrl,
      avatarPresetColor: existing?.avatarPresetColor,
      avatarPresetInitial: existing?.avatarPresetInitial,
      avatarUseIcon: existing?.avatarUseIcon,
    );
    widget.onSave(teacher);
    Navigator.of(context).pop(teacher);
  }

  Future<void> _confirmDelete() async {
    if (widget.onDelete == null || _isOwnerTeacher) return;

    final teacherName = widget.teacher?.name.trim().isNotEmpty == true
        ? widget.teacher!.name.trim()
        : '선생님';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kDlgBg,
        title: Text(
          '$teacherName선생님 삭제',
          style: const TextStyle(
            color: Color(0xFFEAF2F2),
            fontWeight: FontWeight.w700,
          ),
        ),
        content: const Text(
          '정말로 이 선생님을 삭제하시겠습니까?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: PreviewAcademyDialogDestructiveCard.destructiveColor,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await widget.onDelete!();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickRole(PreviewAcademyPanelStyle style) async {
    if (_isOwnerTeacher) return;
    final anchor =
        _roleAnchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (anchor == null) return;

    final pickedId = await PreviewAcademyGlassMenu.show(
      context: context,
      anchor: anchor,
      style: style,
      selectedId: _role.name,
      options: TeacherRole.values
          .map(
            (r) => PreviewAcademyMenuOption(
              id: r.name,
              label: getTeacherRoleLabel(r),
            ),
          )
          .toList(),
    );
    if (pickedId == null || !mounted) return;
    final next = TeacherRole.values.firstWhere((r) => r.name == pickedId);
    setState(() => _role = next);
  }

  @override
  Widget build(BuildContext context) {
    final style = _style(context);
    final title = TeacherRegistrationDialog.titleFor(widget.teacher);
    final existing = widget.teacher;
    final deleteLabel = existing == null
        ? null
        : '${existing.name.trim()}선생님 삭제';

    return PreviewAcademyDialogSheet(
      style: style,
      title: title,
      onCancel: _close,
      onConfirm: _confirm,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PreviewAcademyDialogGroupedFields(
            style: style,
            children: [
              PreviewAcademyDialogFieldRow(
                style: style,
                label: '이름',
                controller: _nameController,
                focusNode: _nameFocusNode,
                textInputAction: TextInputAction.next,
                onSubmitted: _contactFocusNode.requestFocus,
                emptyHintText: '필수입력',
              ),
              Divider(
                height: 1,
                thickness: 1,
                indent: FabTabBarTokens
                    .previewAcademyInputSheetFieldPaddingHorizontal,
                endIndent: FabTabBarTokens
                    .previewAcademyInputSheetFieldPaddingHorizontal,
                color: style.divider,
              ),
              PreviewAcademyDialogPickerRow(
                style: style,
                anchorKey: _roleAnchorKey,
                label: _isOwnerTeacher ? '역할(관리자 고정)' : '역할',
                value: getTeacherRoleLabel(_role),
                valueMuted: _isOwnerTeacher,
                onTap: _isOwnerTeacher ? null : () => _pickRole(style),
              ),
              Divider(
                height: 1,
                thickness: 1,
                indent: FabTabBarTokens
                    .previewAcademyInputSheetFieldPaddingHorizontal,
                endIndent: FabTabBarTokens
                    .previewAcademyInputSheetFieldPaddingHorizontal,
                color: style.divider,
              ),
              PreviewAcademyDialogFieldRow(
                style: style,
                label: '연락처',
                controller: _contactController,
                focusNode: _contactFocusNode,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                onSubmitted: _emailFocusNode.requestFocus,
                emptyHintText: '미입력',
              ),
              Divider(
                height: 1,
                thickness: 1,
                indent: FabTabBarTokens
                    .previewAcademyInputSheetFieldPaddingHorizontal,
                endIndent: FabTabBarTokens
                    .previewAcademyInputSheetFieldPaddingHorizontal,
                color: style.divider,
              ),
              PreviewAcademyDialogFieldRow(
                style: style,
                label: '이메일',
                controller: _emailController,
                focusNode: _emailFocusNode,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                onSubmitted: _descriptionFocusNode.requestFocus,
                emptyHintText: '미입력',
              ),
              Divider(
                height: 1,
                thickness: 1,
                indent: FabTabBarTokens
                    .previewAcademyInputSheetFieldPaddingHorizontal,
                endIndent: FabTabBarTokens
                    .previewAcademyInputSheetFieldPaddingHorizontal,
                color: style.divider,
              ),
              PreviewAcademyDialogFieldRow(
                style: style,
                label: '설명',
                controller: _descriptionController,
                focusNode: _descriptionFocusNode,
                textInputAction: TextInputAction.done,
                onSubmitted: _confirm,
                emptyHintText: '미입력',
              ),
            ],
          ),
          if (widget.onDelete != null &&
              existing != null &&
              deleteLabel != null &&
              !_isOwnerTeacher) ...[
            const SizedBox(
              height: FabTabBarTokens.previewAcademySectionListSpacing,
            ),
            PreviewAcademyDialogDestructiveCard(
              style: style,
              label: deleteLabel,
              onTap: _confirmDelete,
            ),
          ],
        ],
      ),
    );
  }
}
