import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../models/group_info.dart';
import '../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../utils/ime_aware_text_editing_controller.dart';
import 'app_snackbar.dart';

/// 그룹 등록·수정 — 선생님 추가와 같은 입력 시트.
class GroupRegistrationDialog extends StatefulWidget {
  final bool editMode;
  final GroupInfo? groupInfo;
  final int? index;
  final Function(GroupInfo) onSave;
  final int currentMemberCount;

  const GroupRegistrationDialog({
    super.key,
    this.editMode = false,
    this.groupInfo,
    this.index,
    required this.onSave,
    this.currentMemberCount = 0,
  });

  static String titleFor({required bool editMode}) {
    return editMode ? '그룹 수정' : '그룹 등록';
  }

  static Future<GroupInfo?> show({
    required BuildContext context,
    bool editMode = false,
    GroupInfo? groupInfo,
    int? index,
    required Function(GroupInfo) onSave,
    int currentMemberCount = 0,
  }) {
    final title = titleFor(editMode: editMode);
    return PreviewAcademyDialogRoute.show<GroupInfo>(
      context: context,
      barrierLabel: title,
      builder: (context) {
        return GroupRegistrationDialog(
          editMode: editMode,
          groupInfo: groupInfo,
          index: index,
          onSave: onSave,
          currentMemberCount: currentMemberCount,
        );
      },
    );
  }

  @override
  State<GroupRegistrationDialog> createState() =>
      _GroupRegistrationDialogState();
}

class _GroupRegistrationDialogState extends State<GroupRegistrationDialog> {
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _capacityController;
  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _capacityFocusNode = FocusNode();
  final FocusNode _descriptionFocusNode = FocusNode();
  late int _duration;
  late Color _selectedColor;
  bool _unlimitedCapacity = false;

  /// 없음 포함 총 24개 색상 (null + 기본 18 + 추가 5, 마지막은 짙은 네이비).
  final List<Color?> _colors = [
    null,
    ...Colors.primaries,
    const Color(0xFF33A373),
    const Color(0xFF9FB3B3),
    const Color(0xFF6B4EFF),
    const Color(0xFFD1A054),
    const Color(0xFF0F1A2D),
  ];

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  void _bindControllers() {
    for (final controller in [
      _nameController,
      _descriptionController,
      _capacityController,
    ]) {
      controller.addListener(_onFieldChanged);
    }
  }

  void _initControllers() {
    _nameController =
        ImeAwareTextEditingController(text: widget.groupInfo?.name ?? '');
    _descriptionController = ImeAwareTextEditingController(
      text: widget.groupInfo?.description ?? '',
    );
    _capacityController = ImeAwareTextEditingController(
      text: widget.groupInfo?.capacity?.toString() ?? '',
    );
    _duration = widget.groupInfo?.duration ?? 60;
    _selectedColor = widget.groupInfo?.color ?? Colors.blue;
    _unlimitedCapacity = widget.groupInfo?.capacity == null;
    _bindControllers();
  }

  @override
  void initState() {
    super.initState();
    _initControllers();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nameFocusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant GroupRegistrationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.groupInfo != oldWidget.groupInfo) {
      _disposeControllers();
      _initControllers();
      setState(() {});
    }
  }

  void _disposeControllers() {
    for (final controller in [
      _nameController,
      _descriptionController,
      _capacityController,
    ]) {
      controller.removeListener(_onFieldChanged);
      controller.dispose();
    }
  }

  @override
  void dispose() {
    _disposeControllers();
    _nameFocusNode.dispose();
    _capacityFocusNode.dispose();
    _descriptionFocusNode.dispose();
    super.dispose();
  }

  PreviewAcademyPanelStyle _style(BuildContext context) {
    return FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
  }

  Widget _fieldDivider(PreviewAcademyPanelStyle style) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
      endIndent: FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
      color: style.divider,
    );
  }

  void _handleSave() async {
    final name = _nameController.text.trim();
    final description = _descriptionController.text.trim();
    final capacity = _unlimitedCapacity
        ? null
        : int.tryParse(_capacityController.text.trim());
    final duration = _duration;
    final color = _selectedColor;

    if (name.isEmpty) {
      _nameFocusNode.requestFocus();
      showAppSnackBar(context, '그룹명을 입력해주세요', useRoot: true);
      return;
    }

    if (!_unlimitedCapacity &&
        capacity != null &&
        capacity < widget.currentMemberCount) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('정원 오류', style: TextStyle(color: Colors.white)),
          content: Text(
            '현재 그룹 인원(${widget.currentMemberCount}명)보다 적은 정원은 설정할 수 없습니다.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('확인', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );
      return;
    }

    if (!_unlimitedCapacity && capacity == null) {
      showAppSnackBar(context, '정원을 입력하거나 제한없음을 선택하세요', useRoot: true);
      return;
    }

    if (widget.editMode && widget.groupInfo == null) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('오류', style: TextStyle(color: Colors.white)),
          content: const Text('수정할 그룹 정보가 없습니다.',
              style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('확인', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );
      return;
    }

    if (widget.editMode) {
      final old = widget.groupInfo!;
      if (name == old.name &&
          description == old.description &&
          capacity == old.capacity &&
          duration == old.duration &&
          color == old.color) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF1F1F1F),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('수정할 내용이 없습니다.',
                style: TextStyle(color: Colors.white)),
            content: const Text('변경된 내용이 없습니다.',
                style: TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child:
                    const Text('확인', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        );
        return;
      }
      final updatedGroup = old.copyWith(
        name: name,
        description: description,
        capacity: capacity,
        duration: duration,
        color: color,
      );
      widget.onSave(updatedGroup);
      if (mounted) Navigator.of(context).pop(updatedGroup);
    } else {
      final newGroup = GroupInfo(
        id: const Uuid().v4(),
        name: name,
        description: description,
        capacity: capacity,
        duration: duration,
        color: color,
      );
      widget.onSave(newGroup);
      if (mounted) Navigator.of(context).pop(newGroup);
    }
  }

  void _setUnlimited(bool value) {
    setState(() => _unlimitedCapacity = value);
    if (value) _capacityController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final style = _style(context);
    final title = GroupRegistrationDialog.titleFor(editMode: widget.editMode);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final switchInactive =
        isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA);

    return PreviewAcademyDialogSheet(
      style: style,
      title: title,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _handleSave,
      child: PreviewAcademyDialogGroupedFields(
        style: style,
        children: [
          PreviewAcademyDialogFieldRow(
            style: style,
            label: '그룹명',
            controller: _nameController,
            focusNode: _nameFocusNode,
            textInputAction: TextInputAction.next,
            onSubmitted: _unlimitedCapacity
                ? _descriptionFocusNode.requestFocus
                : _capacityFocusNode.requestFocus,
            emptyHintText: '필수입력',
          ),
          _fieldDivider(style),
          PreviewAcademyDialogFieldRow(
            style: style,
            label: '정원',
            controller: _capacityController,
            focusNode: _capacityFocusNode,
            enabled: !_unlimitedCapacity,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.next,
            onSubmitted: _descriptionFocusNode.requestFocus,
            emptyHintText: _unlimitedCapacity ? '제한없음' : '숫자 입력',
          ),
          _fieldDivider(style),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FabTabBarTokens
                  .previewAcademyInputSheetFieldPaddingHorizontal,
              vertical: FabTabBarTokens
                  .previewAcademyInputSheetFieldRowPaddingVertical,
            ),
            child: Row(
              children: [
                SizedBox(
                  width:
                      FabTabBarTokens.previewAcademyInputSheetFieldLabelWidth,
                  child: Text(
                    '제한없음',
                    style: FabTabBarTokens.previewRowLabelStyle(style),
                  ),
                ),
                const Spacer(),
                PreviewAcademyIosSwitch(
                  value: _unlimitedCapacity,
                  inactiveColor: switchInactive,
                  onChanged: _setUnlimited,
                ),
              ],
            ),
          ),
          _fieldDivider(style),
          PreviewAcademyDialogFieldRow(
            style: style,
            label: '설명',
            controller: _descriptionController,
            focusNode: _descriptionFocusNode,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            maxLines: 2,
            minLines: 1,
            emptyHintText: '미입력',
          ),
          _fieldDivider(style),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
              16,
              FabTabBarTokens.previewAcademyInputSheetFieldPaddingHorizontal,
              20,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '색상',
                  style: FabTabBarTokens.previewRowLabelStyle(style),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final color in _colors)
                      _ColorSwatch(
                        color: color,
                        selected: color == null
                            ? _selectedColor == Colors.transparent
                            : _selectedColor == color,
                        selectedBorder: style.title,
                        idleBorder: style.divider,
                        iconColor: style.hint,
                        onTap: () => setState(
                          () => _selectedColor = color ?? Colors.transparent,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  final Color? color;
  final bool selected;
  final Color selectedBorder;
  final Color idleBorder;
  final Color iconColor;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.selectedBorder,
    required this.idleBorder,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color ?? Colors.transparent,
          border: Border.all(
            color: selected ? selectedBorder : idleBorder,
            width: selected ? 2.5 : 1.4,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: color == null
            ? Center(
                child: Icon(Icons.close_rounded, color: iconColor, size: 18))
            : null,
      ),
    );
  }
}
