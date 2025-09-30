import 'package:flutter/material.dart';
import '../../services/data_manager.dart';

class StudentProfilePage extends StatelessWidget {
  final StudentWithInfo studentWithInfo;

  const StudentProfilePage({super.key, required this.studentWithInfo});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF18181A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        elevation: 0,
        title: Text(
          studentWithInfo.student.name,
          style: const TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: Text(
          '학생 페이지 (준비 중)',
          style: const TextStyle(color: Colors.white70, fontSize: 18),
        ),
      ),
    );
  }
}


