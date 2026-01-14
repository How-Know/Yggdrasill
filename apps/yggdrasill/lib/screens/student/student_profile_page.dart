import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/data_manager.dart';
import '../../models/student.dart';
import '../../models/education_level.dart';

class StudentProfilePage extends StatelessWidget {
  final StudentWithInfo studentWithInfo;

  const StudentProfilePage({super.key, required this.studentWithInfo});

  @override
  Widget build(BuildContext context) {
    // ClassStatusScreen과 동일한 구조 적용
    return Scaffold(
      backgroundColor: const Color(0xFF0B1112),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: 0), // 왼쪽 여백 (AllStudentsView와 일치)
          Expanded(
            flex: 2,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Container(
                  constraints: const BoxConstraints(
                    minWidth: 624,
                  ),
                  padding: const EdgeInsets.only(left: 34, right: 24, top: 24, bottom: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B1112),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 1),
                      // 헤더 영역
                      _StudentProfileHeader(studentWithInfo: studentWithInfo),
                      const SizedBox(height: 24),
                      // 메인 콘텐츠 영역
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B1112),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const _StudentProfileContent(),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StudentProfileHeader extends StatelessWidget {
  final StudentWithInfo studentWithInfo;

  const _StudentProfileHeader({required this.studentWithInfo});

  @override
  Widget build(BuildContext context) {
    final student = studentWithInfo.student;
    final basicInfo = studentWithInfo.basicInfo;
    final String levelName = getEducationLevelName(student.educationLevel);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 22),
      decoration: BoxDecoration(
        color: const Color(0xFF223131),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              // 뒤로가기 버튼
              Container(
                width: 40,
                height: 40,
                margin: const EdgeInsets.only(right: 16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '뒤로',
                  padding: EdgeInsets.zero,
                ),
              ),
              CircleAvatar(
                radius: 20,
                backgroundColor: student.groupInfo?.color ?? const Color(0xFF2C3A3A),
                child: Text(
                  student.name.characters.take(1).toString(),
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 16),
              Text(
                student.name,
                style: const TextStyle(
                  color: Color(0xFFEAF2F2),
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 15),
              Text(
                '$levelName · ${student.grade}학년 · ${student.school}',
                style: const TextStyle(
                  color: Color(0xFFCBD8D8),
                  fontSize: 18,
                ),
              ),
            ],
          ),
          Text(
            '등록일 ${DateFormat('yyyy.MM.dd').format(basicInfo.registrationDate ?? DateTime.now())}',
            style: const TextStyle(
              color: Color(0xFFCBD8D8),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

class _StudentProfileContent extends StatelessWidget {
  const _StudentProfileContent();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.construction_rounded, size: 64, color: Colors.white.withOpacity(0.1)),
          const SizedBox(height: 16),
          Text(
            '학생 상세 페이지 준비 중입니다.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}