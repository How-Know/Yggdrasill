import 'package:flutter/material.dart';

import 'package:intl/intl.dart';

import '../../../services/data_manager.dart';
import '../../../models/payment_record.dart';
import '../../../models/student.dart';

class StudentPaymentOverviewSection extends StatelessWidget {
  final StudentWithInfo studentWithInfo;
  final Future<void> Function(StudentWithInfo) onShowHistory;
  final Future<void> Function(PaymentRecord) onEditDueDate;

  const StudentPaymentOverviewSection({
    super.key,
    required this.studentWithInfo,
    required this.onShowHistory,
    required this.onEditDueDate,
  });

  @override
  Widget build(BuildContext context) {
    final student = studentWithInfo.student;
    final payments = DataManager.instance.getPaymentRecordsForStudent(student.id)
      ..sort((a, b) => b.dueDate.compareTo(a.dueDate));
    final upcoming = payments.firstWhere(
      (record) => record.paidDate == null,
      orElse: () => payments.isNotEmpty ? payments.first : PaymentRecord(studentId: student.id, cycle: 1, dueDate: DateTime.now()),
    );

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F151B),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF223131)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('수강료 개요', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(
                onPressed: () => onShowHistory(studentWithInfo),
                child: const Text('전체 보기', style: TextStyle(color: Color(0xFF8FA4A4))),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '다음 납부 예정일',
            style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            DateFormat('yyyy년 MM월 dd일').format(upcoming.dueDate),
            style: const TextStyle(color: Color(0xFF90CAF9), fontSize: 20, fontWeight: FontWeight.w800),
          ),
          if (upcoming.paidDate != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '납부 완료 (${DateFormat('MM.dd').format(upcoming.paidDate!)})',
                style: const TextStyle(color: Colors.white60),
              ),
            ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => onEditDueDate(upcoming),
            child: const Text('예정일 수정'),
          ),
        ],
      ),
    );
  }
}

