import 'package:flutter/material.dart';
import '../models/class_info.dart';

class ClassRegistrationDialog extends StatefulWidget {
  final bool editMode;
  final ClassInfo? classInfo;

  const ClassRegistrationDialog({
    super.key,
    this.editMode = false,
    this.classInfo,
  });

  @override
  State<ClassRegistrationDialog> createState() => _ClassRegistrationDialogState();
}

class _ClassRegistrationDialogState extends State<ClassRegistrationDialog> {
  late final TextEditingController nameController;
  late final TextEditingController descriptionController;
  late final TextEditingController capacityController;
  late Color selectedColor;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.classInfo?.name ?? '');
    descriptionController = TextEditingController(text: widget.classInfo?.description ?? '');
    capacityController = TextEditingController(text: widget.classInfo?.capacity.toString() ?? '');
    selectedColor = widget.classInfo?.color ?? Colors.blue;
  }

  @override
  void dispose() {
    nameController.dispose();
    descriptionController.dispose();
    capacityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(
        widget.editMode ? '클래스 수정' : '새 클래스 등록',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '기본 정보',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              // 이름과 정원을 나란히 배치 (3:2 비율)
              Row(
                children: [
                  // 이름
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: nameController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: '클래스 이름',
                        labelStyle: const TextStyle(color: Colors.white70),
                        hintText: '클래스 이름을 입력하세요',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
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
                  // 정원
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: capacityController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: '정원',
                        labelStyle: const TextStyle(color: Colors.white70),
                        hintText: '정원',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF1976D2)),
                        ),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 설명 (2줄 높이)
              TextField(
                controller: descriptionController,
                style: const TextStyle(color: Colors.white),
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: '설명',
                  labelStyle: const TextStyle(color: Colors.white70),
                  hintText: '클래스 설명을 입력하세요',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // 색상 선택
              const Text(
                '클래스 색상',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 16),
              // 색상 선택 그리드 (10x2)
              SizedBox(
                height: 96,
                child: GridView.count(
                  crossAxisCount: 10,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    // 첫 번째 줄: 밝은 색상들
                    Colors.red[500]!, // 빨강
                    Colors.pink[400]!, // 분홍
                    Colors.purple[400]!, // 보라
                    Colors.deepPurple[400]!, // 진보라
                    Colors.blue[500]!, // 파랑
                    Colors.lightBlue[400]!, // 하늘색
                    Colors.cyan[500]!, // 청록
                    Colors.teal[500]!, // 틸
                    Colors.green[500]!, // 초록
                    Colors.lightGreen[500]!, // 연두
                    // 두 번째 줄: 다양한 색조와 채도
                    Colors.amber[600]!, // 황금색
                    Colors.orange[600]!, // 주황
                    Colors.deepOrange[400]!, // 진주황
                    Colors.brown[400]!, // 갈색
                    Colors.blueGrey[400]!, // 블루그레이
                    Colors.indigo[400]!, // 인디고
                    Colors.lime[600]!, // 라임
                    Colors.yellow[600]!, // 노랑
                    const Color(0xFF2196F3), // 밝은 파랑
                    const Color(0xFF607D8B), // 그레이
                  ].map((color) {
                    return InkWell(
                      onTap: () {
                        setState(() {
                          selectedColor = color;
                        });
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selectedColor == color ? Colors.white : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
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
          onPressed: () {
            final name = nameController.text.trim();
            final description = descriptionController.text.trim();
            final capacity = int.tryParse(capacityController.text.trim());

            if (name.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('클래스 이름을 입력해주세요')),
              );
              return;
            }

            if (capacity == null || capacity <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('올바른 정원을 입력해주세요')),
              );
              return;
            }

            final classInfo = ClassInfo(
              id: widget.classInfo?.id,
              name: name,
              description: description,
              capacity: capacity,
              color: selectedColor,
            );

            Navigator.pop(context, classInfo);
          },
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
          ),
          child: Text(widget.editMode ? '수정' : '등록'),
        ),
      ],
    );
  }
} 