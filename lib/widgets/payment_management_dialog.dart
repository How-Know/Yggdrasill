import 'package:flutter/material.dart';
import '../models/student.dart';
import '../services/data_manager.dart';
import '../models/payment_record.dart';

class PaymentManagementDialog extends StatefulWidget {
  const PaymentManagementDialog({super.key});

  @override
  State<PaymentManagementDialog> createState() => _PaymentManagementDialogState();
}

class _PaymentManagementDialogState extends State<PaymentManagementDialog> {
  List<StudentWithInfo> _overdueStudents = [];
  List<StudentWithInfo> _upcomingStudents = [];
  List<StudentWithInfo> _paidThisMonthStudents = [];
  int _totalThisMonthCount = 0;

  @override
  void initState() {
    super.initState();
    _loadPaymentData();
  }

  void _loadPaymentData() {
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    final students = DataManager.instance.students;

    List<StudentWithInfo> overdueStudents = [];
    List<StudentWithInfo> upcomingStudents = [];
    List<StudentWithInfo> paidThisMonthStudents = [];

    for (var studentWithInfo in students) {
      final registrationDate = studentWithInfo.basicInfo.registrationDate;
      if (registrationDate == null) continue;

      // 이번달 결제 정보 확인
      final thisMonthPaymentDate = _getActualPaymentDateForMonth(
        studentWithInfo.student.id, 
        registrationDate, 
        currentMonth
      );
      final thisMonthCycle = _calculateCycleNumber(registrationDate, thisMonthPaymentDate);
      final thisMonthRecord = DataManager.instance.getPaymentRecord(studentWithInfo.student.id, thisMonthCycle);

      // 이번달 결제 완료 여부 확인
      if (thisMonthRecord?.paidDate != null) {
        paidThisMonthStudents.add(studentWithInfo);
      } else {
        // 미결제자 분류
        if (thisMonthPaymentDate.isBefore(now)) {
          // 결제 예정일이 지남 (연체)
          overdueStudents.add(studentWithInfo);
        } else {
          // 아직 결제 예정일 전
          upcomingStudents.add(studentWithInfo);
        }
      }
    }

    setState(() {
      _overdueStudents = overdueStudents;
      _upcomingStudents = upcomingStudents;
      _paidThisMonthStudents = paidThisMonthStudents;
      _totalThisMonthCount = paidThisMonthStudents.length + overdueStudents.length + upcomingStudents.length;
    });
  }

  DateTime _getActualPaymentDateForMonth(String studentId, DateTime registrationDate, DateTime targetMonth) {
    final defaultDate = DateTime(targetMonth.year, targetMonth.month, registrationDate.day);
    final cycle = _calculateCycleNumber(registrationDate, defaultDate);
    
    final record = DataManager.instance.getPaymentRecord(studentId, cycle);
    if (record != null) {
      return record.dueDate;
    }
    
    return defaultDate;
  }

  int _calculateCycleNumber(DateTime registrationDate, DateTime paymentDate) {
    final regMonth = DateTime(registrationDate.year, registrationDate.month);
    final payMonth = DateTime(paymentDate.year, paymentDate.month);
    return (payMonth.year - regMonth.year) * 12 + (payMonth.month - regMonth.month) + 1;
  }

  Widget _buildPaymentStudentCard(StudentWithInfo studentWithInfo, {bool isOverdue = false}) {
    final student = studentWithInfo.student;
    final registrationDate = studentWithInfo.basicInfo.registrationDate!;
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    
    final paymentDate = _getActualPaymentDateForMonth(student.id, registrationDate, currentMonth);
    final cycle = _calculateCycleNumber(registrationDate, paymentDate);

    return Tooltip(
      message: '결제 사이클: ${cycle}번째\n결제 예정일: ${paymentDate.month}/${paymentDate.day}',
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 14),
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        height: 58,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
        decoration: BoxDecoration(
          color: isOverdue ? const Color(0xFF2A2A2A) : const Color(0xFF1F1F1F),
          border: isOverdue 
            ? Border.all(color: Colors.red.withOpacity(0.3), width: 1)
            : Border.all(color: Colors.transparent, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                student.name,
                style: TextStyle(
                  color: isOverdue ? Colors.red.shade300 : const Color(0xFFE0E0E0),
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              '${paymentDate.month}/${paymentDate.day}',
              style: TextStyle(
                color: isOverdue ? Colors.red.shade400 : Colors.white54,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPaidStudentsList() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF232326),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('이번달 결제 완료 명단', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 400,
          height: 300,
          child: Column(
            children: [
              // 헤더
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                decoration: const BoxDecoration(
                  color: Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(8),
                    topRight: Radius.circular(8),
                  ),
                ),
                child: const Row(
                  children: [
                    Expanded(flex: 2, child: Text('학생명', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold))),
                    Expanded(flex: 2, child: Text('결제 예정일', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold))),
                    Expanded(flex: 2, child: Text('실제 결제일', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold))),
                  ],
                ),
              ),
              // 리스트
              Expanded(
                child: ListView.builder(
                  itemCount: _paidThisMonthStudents.length,
                  itemBuilder: (context, index) {
                    final studentWithInfo = _paidThisMonthStudents[index];
                    final student = studentWithInfo.student;
                    final registrationDate = studentWithInfo.basicInfo.registrationDate!;
                    final now = DateTime.now();
                    final currentMonth = DateTime(now.year, now.month);
                    
                    final paymentDate = _getActualPaymentDateForMonth(student.id, registrationDate, currentMonth);
                    final cycle = _calculateCycleNumber(registrationDate, paymentDate);
                    final record = DataManager.instance.getPaymentRecord(student.id, cycle);

                    return Container(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: index.isEven ? const Color(0xFF1F1F1F) : const Color(0xFF2A2A2A),
                      ),
                      child: Row(
                        children: [
                          Expanded(flex: 2, child: Text(student.name, style: const TextStyle(color: Colors.white))),
                          Expanded(flex: 2, child: Text('${paymentDate.month}/${paymentDate.day}', style: const TextStyle(color: Colors.white70))),
                          Expanded(flex: 2, child: Text(
                            record?.paidDate != null ? '${record!.paidDate!.month}/${record.paidDate!.day}' : '-',
                            style: const TextStyle(color: Color(0xFF4CAF50))
                          )),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF232326),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 800,
        height: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 제목
            const Text(
              '수강료 결제 관리',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            
            // 메인 컨테이너
            Expanded(
              child: Row(
                children: [
                  // 왼쪽 컨테이너 (연체자 - 파란색)
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF212A31), // 슬라이드시트 파란 컨테이너와 같은 색
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.warning, color: Colors.red, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                '결제 예정일 지남 (${_overdueStudents.length}명)',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _overdueStudents.length,
                              itemBuilder: (context, index) {
                                return _buildPaymentStudentCard(_overdueStudents[index], isOverdue: true);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(width: 16),
                  
                  // 오른쪽 컨테이너 (예정자 - 일반)
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F1F1F),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.schedule, color: Colors.blue, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                '결제 예정 (${_upcomingStudents.length}명)',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _upcomingStudents.length,
                              itemBuilder: (context, index) {
                                return _buildPaymentStudentCard(_upcomingStudents[index]);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 16),
            
            // 하단 통계 및 더보기 버튼
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '이번달 결제 현황: ${_paidThisMonthStudents.length}/${_totalThisMonthCount}명 완료',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _showPaidStudentsList,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1976D2),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('더보기'),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 16),
            
            // 닫기 버튼
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('닫기', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}