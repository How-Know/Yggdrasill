import 'package:flutter/material.dart';
import '../models/teacher.dart';

class TeacherDetailsDialog extends StatelessWidget {
  final Teacher teacher;
  const TeacherDetailsDialog({Key? key, required this.teacher}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1F1F1F), // 다이얼로그 배경색 변경
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 상단: 이름, 역할
            Text(
              teacher.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              getTeacherRoleLabel(teacher.role),
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 16),
            // 정보 카드
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1F1F1F), // 정보 카드 배경색도 검정색으로 변경
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.phone, color: Colors.white38, size: 18),
                      const SizedBox(width: 8),
                      Text('연락처: ', style: TextStyle(color: Colors.white70, fontSize: 15)),
                      Text(
                        teacher.contact.isNotEmpty ? teacher.contact : '정보 없음',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.email, color: Colors.white38, size: 18),
                      const SizedBox(width: 8),
                      Text('이메일: ', style: TextStyle(color: Colors.white70, fontSize: 15)),
                      Text(
                        teacher.email.isNotEmpty ? teacher.email : '정보 없음',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, color: Colors.white38, size: 18),
                      const SizedBox(width: 8),
                      Text('설명: ', style: TextStyle(color: Colors.white70, fontSize: 15)),
                      Expanded(
                        child: Text(
                          teacher.description.isNotEmpty ? teacher.description : '정보 없음',
                          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerRight, // 오른쪽 정렬
              child: SizedBox(
                width: 96, // 20% 감소
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1976D2), // 시그니처 색상
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), // 라운드 크게
                    elevation: 0,
                  ),
                  child: const Text('닫기', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
} 