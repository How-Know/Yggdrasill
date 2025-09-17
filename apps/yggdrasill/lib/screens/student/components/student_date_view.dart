import 'package:flutter/material.dart';

class StudentDateView extends StatelessWidget {
  const StudentDateView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24.0),
        child: Text(
          '준비 중입니다.',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 18,
          ),
        ),
      ),
    );
  }
} 