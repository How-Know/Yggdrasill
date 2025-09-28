import 'package:flutter/material.dart';
import '../models/student.dart';
import '../services/data_manager.dart';
import '../models/payment_record.dart';

class PaymentManagementDialog extends StatefulWidget {
  final VoidCallback? onClose;
  
  const PaymentManagementDialog({super.key, this.onClose});

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

    return _PaymentStudentCard(
      studentWithInfo: studentWithInfo,
      paymentDate: paymentDate,
      cycle: cycle,
      isOverdue: isOverdue,
      onClose: widget.onClose,
    );
  }

  void _showPaidStudentsList() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
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
      backgroundColor: const Color(0xFF1F1F1F), // 학생등록 다이얼로그와 동일한 배경색
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
                            child: GridView.builder(
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2, // 2열로 배치
                                childAspectRatio: 2.5, // 카드 비율
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
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
                            child: GridView.builder(
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2, // 2열로 배치
                                childAspectRatio: 2.5, // 카드 비율
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
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
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onClose?.call(); // FAB 닫기 콜백 호출
                    },
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

// 슬라이드시트 출석체크 카드와 동일한 스타일의 결제 학생 카드
class _PaymentStudentCard extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  final DateTime paymentDate;
  final int cycle;
  final bool isOverdue;
  final VoidCallback? onClose;

  const _PaymentStudentCard({
    required this.studentWithInfo,
    required this.paymentDate,
    required this.cycle,
    required this.isOverdue,
    this.onClose,
  });

  @override
  State<_PaymentStudentCard> createState() => _PaymentStudentCardState();
}

class _PaymentStudentCardState extends State<_PaymentStudentCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final student = widget.studentWithInfo.student;
    
    return Tooltip(
      message: '결제 사이클: ${widget.cycle}번째\n결제 예정일: ${widget.paymentDate.month}/${widget.paymentDate.day}',
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 14),
      waitDuration: const Duration(milliseconds: 300),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: () => _handlePaymentTap(context),
          child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: widget.isOverdue ? Colors.transparent : const Color(0xFF2A2A2A),
            border: widget.isOverdue 
              ? Border.all(color: Colors.red.withOpacity(0.5), width: 2)
              : (_isHovered 
                ? Border.all(color: const Color(0xFF1976D2), width: 2)
                : Border.all(color: Colors.transparent, width: 2)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    student.name,
                    style: const TextStyle(
                      color: Color(0xFFE0E0E0), // 연체자도 같은 색상
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.paymentDate.month}/${widget.paymentDate.day} 예정',
                    style: const TextStyle(
                      color: Colors.white54, // 연체자도 같은 색상
                      fontSize: 12,
                    ),
                  ),
                ],
              ),

            ],
          ),
          ),
        ),
      ),
    );
  }

  void _handlePaymentTap(BuildContext context) async {
    // 바로 결제 처리
    await _processPayment();
    
    // 결제 완료 메시지
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${widget.studentWithInfo.student.name} 학생의 수강료 납부가 완료되었습니다.'),
          backgroundColor: const Color(0xFF4CAF50),
          behavior: SnackBarBehavior.floating,
        ),
      );
      
      // 부모 다이얼로그 새로고침을 위해 pop 후 재로드
      Navigator.of(context).pop();
      showDialog(
        context: context,
        builder: (context) => PaymentManagementDialog(onClose: widget.onClose),
      );
    }
  }

  Future<void> _processPayment() async {
    final now = DateTime.now();
    final registrationDate = widget.studentWithInfo.basicInfo.registrationDate!;
    
    // 기존 레코드 확인
    final existingRecord = DataManager.instance.getPaymentRecord(
      widget.studentWithInfo.student.id, 
      widget.cycle
    );

    final paymentRecord = PaymentRecord(
      id: existingRecord?.id,
      studentId: widget.studentWithInfo.student.id,
      cycle: widget.cycle,
      dueDate: widget.paymentDate,
      paidDate: now, // 현재 시간을 납부일로 설정
    );

    // 서버-우선 모드에서는 RPC를 사용하여 결제 처리
    await DataManager.instance.recordPayment(
      widget.studentWithInfo.student.id,
      widget.cycle,
      now,
    );
  }
}