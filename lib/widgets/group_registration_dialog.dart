import 'package:flutter/material.dart';
import '../models/group_info.dart';
import 'package:uuid/uuid.dart';

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
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.lightGreen,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
    Colors.deepOrange,
    Colors.brown,
    Colors.grey,
    Colors.blueGrey,
    const Color(0xFF2196F3),
  ];

  void _initControllers() {
    print('[DEBUG] _initControllers: groupInfo=${widget.groupInfo}');
    _nameController = TextEditingController(text: widget.groupInfo?.name ?? '');
    _descriptionController = TextEditingController(text: widget.groupInfo?.description ?? '');
    _capacityController = TextEditingController(text: widget.groupInfo?.capacity?.toString() ?? '');
    _duration = widget.groupInfo?.duration ?? 60;
    _selectedColor = widget.groupInfo?.color ?? Colors.blue;
  }

  @override
  void initState() {
    super.initState();
    print('[DEBUG] initState: groupInfo=${widget.groupInfo}');
    _initControllers();
  }

  @override
  void didUpdateWidget(covariant GroupRegistrationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.groupInfo != oldWidget.groupInfo) {
      print('[DEBUG] didUpdateWidget: groupInfo=${widget.groupInfo}');
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

    print('[DEBUG] _handleSave: name=$name, description=$description, capacity=$capacity, duration=$duration, color=$color');
    if (widget.editMode && widget.groupInfo != null) {
      final old = widget.groupInfo!;
      print('[DEBUG] _handleSave: old.name=${old.name}, old.description=${old.description}, old.capacity=${old.capacity}, old.duration=${old.duration}, old.color=${old.color}');
      print('[DEBUG] _handleSave: 비교 결과 name=${name == old.name}, description=${description == old.description}, capacity=${capacity == old.capacity}, duration=${duration == old.duration}, color=${color == old.color}');
    }

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('그룹명을 입력해주세요'),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(bottom: 80, left: 20, right: 20),
        ),
      );
      return;
    }

    if (capacity < widget.currentMemberCount) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF232326),
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
          backgroundColor: const Color(0xFF232326),
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
            backgroundColor: const Color(0xFF232326),
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(
        widget.editMode ? '그룹 수정' : '그룹 등록',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '그룹명',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _capacityController,
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '정원',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              style: const TextStyle(color: Colors.white),
              maxLines: 2,
              decoration: InputDecoration(
                labelText: '설명',
                labelStyle: const TextStyle(color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '색상',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _colors.map((color) {
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
                        border: Border.all(
                          color: _selectedColor == color ? Colors.white : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            '취소',
            style: TextStyle(color: Colors.white70),
          ),
        ),
        FilledButton(
          onPressed: _handleSave,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
          ),
          child: Text(widget.editMode ? '수정' : '등록'),
        ),
      ],
    );
  }
} 