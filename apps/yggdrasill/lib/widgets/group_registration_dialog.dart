import 'package:flutter/material.dart';
import '../models/group_info.dart';
import 'package:uuid/uuid.dart';
import 'app_snackbar.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

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

  @override
  State<GroupRegistrationDialog> createState() => _GroupRegistrationDialogState();
}

class _GroupRegistrationDialogState extends State<GroupRegistrationDialog> {
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _capacityController;
  late int _duration;
  late Color _selectedColor;

  final List<Color> _colors = [
    Colors.red, Colors.pink, Colors.purple, Colors.deepPurple,
    Colors.indigo, Colors.blue, Colors.lightBlue, Colors.cyan,
    Colors.teal, Colors.green, Colors.lightGreen, Colors.lime,
    Colors.yellow, Colors.amber, Colors.orange, Colors.deepOrange,
    Colors.brown, Colors.grey, Colors.blueGrey, const Color(0xFF2196F3),
  ];

  // 입력 완료 상태 확인용
  bool _isNameValid = false;

  void _initControllers() {
    _nameController = ImeAwareTextEditingController(text: widget.groupInfo?.name ?? '');
    _descriptionController = ImeAwareTextEditingController(text: widget.groupInfo?.description ?? '');
    _capacityController = ImeAwareTextEditingController(text: widget.groupInfo?.capacity?.toString() ?? '');
    _duration = widget.groupInfo?.duration ?? 60;
    _selectedColor = widget.groupInfo?.color ?? Colors.blue;

    _isNameValid = _nameController.text.isNotEmpty;
    _nameController.addListener(() {
      setState(() {
        _isNameValid = _nameController.text.isNotEmpty;
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  @override
  void didUpdateWidget(covariant GroupRegistrationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.groupInfo != oldWidget.groupInfo) {
      _nameController.dispose();
      _descriptionController.dispose();
      _capacityController.dispose();
      _initControllers();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _capacityController.dispose();
    super.dispose();
  }

  void _handleSave() async {
    final name = _nameController.text.trim();
    final description = _descriptionController.text.trim();
    final capacity = int.tryParse(_capacityController.text.trim()) ?? 30;
    final duration = _duration;
    final color = _selectedColor;

    if (name.isEmpty) {
      showAppSnackBar(context, '그룹명을 입력해주세요', useRoot: true);
      return;
    }

    if (capacity < widget.currentMemberCount) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('정원 오류', style: TextStyle(color: Colors.white)),
          content: Text('현재 그룹 인원(${widget.currentMemberCount}명)보다 적은 정원은 설정할 수 없습니다.', style: const TextStyle(color: Colors.white70)),
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

    if (widget.editMode && widget.groupInfo == null) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('오류', style: TextStyle(color: Colors.white)),
          content: const Text('수정할 그룹 정보가 없습니다.', style: TextStyle(color: Colors.white70)),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('수정할 내용이 없습니다.', style: TextStyle(color: Colors.white)),
            content: const Text('변경된 내용이 없습니다.', style: TextStyle(color: Colors.white70)),
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

  InputDecoration _buildInputDecoration(String label, {bool required = false, bool isValid = false}) {
    return InputDecoration(
      labelText: required ? '$label *' : label,
      labelStyle: const TextStyle(color: Color(0xFF9FB3B3), fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: const Color(0xFF3A3F44).withOpacity(0.6)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF33A373)),
      ),
      filled: true,
      fillColor: const Color(0xFF15171C),
      suffixIcon: (required && isValid) 
          ? const Icon(Icons.check_circle, color: Color(0xFF33A373), size: 18) 
          : null,
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: const Color(0xFF33A373),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0B1112),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF223131)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      title: Text(
        widget.editMode ? '그룹 수정' : '그룹 등록',
        style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 20, fontWeight: FontWeight.bold),
      ),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 20),

              // 1. 기본 정보
              _buildSectionHeader('기본 정보'),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _nameController,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      decoration: _buildInputDecoration('그룹명', required: true, isValid: _isNameValid),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _capacityController,
                      style: const TextStyle(color: Color(0xFFEAF2F2)),
                      keyboardType: TextInputType.number,
                      decoration: _buildInputDecoration('정원'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                style: const TextStyle(color: Color(0xFFEAF2F2)),
                maxLines: 2,
                decoration: _buildInputDecoration('설명'),
              ),

              const SizedBox(height: 24),
              const Divider(color: Color(0xFF223131), height: 1),
              const SizedBox(height: 20),

              // 2. 색상 설정
              _buildSectionHeader('색상 설정'),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _colors.map((color) {
                  final isSelected = _selectedColor == color;
                  return Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _selectedColor = color;
                        });
                      },
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: isSelected 
                              ? Border.all(color: Colors.white, width: 3)
                              : null,
                          boxShadow: isSelected 
                              ? [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 4, spreadRadius: 1)]
                              : null,
                        ),
                        child: isSelected 
                            ? const Icon(Icons.check, color: Colors.white, size: 24)
                            : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF9FB3B3),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF33A373), // Accent color
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(
            widget.editMode ? '수정' : '등록',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
