import 'package:flutter/material.dart';
import '../models/student.dart';
import '../services/data_manager.dart';

const Color _pmBg = Color(0xFF0B1112);
const Color _pmPanelBg = Color(0xFF10171A);
const Color _pmCardBg = Color(0xFF15171C);
const Color _pmBorder = Color(0xFF223131);
const Color _pmText = Color(0xFFEAF2F2);
const Color _pmTextSub = Color(0xFF9FB3B3);
const Color _pmAccent = Color(0xFF33A373);
const Color _pmDanger = Color(0xFFF04747);

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
  bool _didNotifyClosed = false;
  late final ScrollController _overdueScrollCtrl;
  late final ScrollController _upcomingScrollCtrl;
  late final ScrollController _paidListScrollCtrl;

  @override
  void initState() {
    super.initState();
    _overdueScrollCtrl = ScrollController();
    _upcomingScrollCtrl = ScrollController();
    _paidListScrollCtrl = ScrollController();
    _loadPaymentData();
    DataManager.instance.paymentRecordsNotifier.addListener(_loadPaymentData);
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

  @override
  void dispose() {
    DataManager.instance.paymentRecordsNotifier.removeListener(_loadPaymentData);
    _overdueScrollCtrl.dispose();
    _upcomingScrollCtrl.dispose();
    _paidListScrollCtrl.dispose();
    _notifyClosed();
    super.dispose();
  }

  void _notifyClosed() {
    if (_didNotifyClosed) return;
    _didNotifyClosed = true;
    widget.onClose?.call();
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
      builder: (context) {
        return Dialog(
          backgroundColor: _pmBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          insetPadding: const EdgeInsets.all(24),
          child: Container(
            width: 720,
            height: 560,
            padding: const EdgeInsets.fromLTRB(26, 26, 26, 18),
            decoration: BoxDecoration(
              color: _pmBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _pmBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        margin: const EdgeInsets.only(right: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: IconButton(
                          tooltip: '닫기',
                          icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
                          padding: EdgeInsets.zero,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                      const Text(
                        '이번달 결제 완료 명단',
                        style: TextStyle(
                          color: _pmText,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                  decoration: BoxDecoration(
                    color: _pmPanelBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _pmBorder),
                  ),
                  child: const Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text('학생명', style: TextStyle(color: _pmTextSub, fontWeight: FontWeight.w700)),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text('결제 예정일', style: TextStyle(color: _pmTextSub, fontWeight: FontWeight.w700)),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text('실제 결제일', style: TextStyle(color: _pmTextSub, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _paidThisMonthStudents.isEmpty
                      ? const Center(
                          child: Text('완료된 결제가 없습니다.', style: TextStyle(color: Colors.white24, fontSize: 13)),
                        )
                      : Scrollbar(
                          thumbVisibility: true,
                          controller: _paidListScrollCtrl,
                          child: ListView.separated(
                            controller: _paidListScrollCtrl,
                            primary: false,
                            itemCount: _paidThisMonthStudents.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final studentWithInfo = _paidThisMonthStudents[index];
                              final student = studentWithInfo.student;
                              final registrationDate = studentWithInfo.basicInfo.registrationDate!;
                              final now = DateTime.now();
                              final currentMonth = DateTime(now.year, now.month);

                              final paymentDate = _getActualPaymentDateForMonth(student.id, registrationDate, currentMonth);
                              final cycle = _calculateCycleNumber(registrationDate, paymentDate);
                              final record = DataManager.instance.getPaymentRecord(student.id, cycle);
                              final paid = record?.paidDate;

                              return Container(
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                                decoration: BoxDecoration(
                                  color: _pmCardBg,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: _pmBorder.withOpacity(0.9)),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        student.name,
                                        style: const TextStyle(color: _pmText, fontSize: 15, fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        '${paymentDate.month}/${paymentDate.day}',
                                        style: const TextStyle(color: _pmTextSub, fontSize: 14, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        paid != null ? '${paid.month}/${paid.day}' : '-',
                                        style: const TextStyle(color: _pmAccent, fontSize: 14, fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    final completed = _paidThisMonthStudents.length;
    final total = _totalThisMonthCount;
    return SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IconButton(
                  tooltip: '닫기',
                  icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    Navigator.of(context).pop();
                    _notifyClosed();
                  },
                ),
              ),
              const Text(
                '수강료 결제 관리',
                style: TextStyle(
                  color: _pmText,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          Positioned(
            right: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '완료 $completed/$total',
                  style: const TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _paidThisMonthStudents.isEmpty ? null : _showPaidStudentsList,
                  icon: const Icon(Icons.list_alt, size: 18),
                  label: const Text('완료 명단'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: _pmBorder),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '새로 고침',
                  onPressed: () async {
                    try {
                      await DataManager.instance.loadPaymentRecords();
                    } catch (_) {}
                    if (mounted) _loadPaymentData();
                  },
                  icon: const Icon(Icons.refresh, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryBar() {
    Text metric(String label, int count, Color color) {
      return Text(
        '$label $count',
        style: TextStyle(
          color: color.withOpacity(0.92),
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _pmPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _pmBorder),
      ),
      child: Row(
        children: [
          const Text('이번달', style: TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          metric('연체', _overdueStudents.length, _pmDanger),
          const SizedBox(width: 10),
          const Text('·', style: TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          metric('예정', _upcomingStudents.length, const Color(0xFF1976D2)),
          const SizedBox(width: 10),
          const Text('·', style: TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          metric('완료', _paidThisMonthStudents.length, _pmAccent),
          const Spacer(),
          Text(
            '총 ${_totalThisMonthCount}명',
            style: const TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required List<StudentWithInfo> students,
    required bool isOverdue,
    required ScrollController scrollController,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _pmPanelBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _pmBorder),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: iconColor.withOpacity(0.35)),
                ),
                child: Icon(icon, color: iconColor, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$title (${students.length}명)',
                      style: const TextStyle(color: _pmText, fontSize: 16, fontWeight: FontWeight.w800),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(color: _pmTextSub, fontSize: 12, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0x22FFFFFF)),
          const SizedBox(height: 12),
          Expanded(
            child: students.isEmpty
                ? const Center(
                    child: Text('대상이 없습니다.', style: TextStyle(color: Colors.white24, fontSize: 13)),
                  )
                : Scrollbar(
                    thumbVisibility: true,
                    controller: scrollController,
                    child: GridView.builder(
                      controller: scrollController,
                      primary: false,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        childAspectRatio: 2.55,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: students.length,
                      itemBuilder: (context, index) {
                        return _buildPaymentStudentCard(students[index], isOverdue: isOverdue);
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _pmBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: 920,
        height: 680,
        padding: const EdgeInsets.fromLTRB(26, 26, 26, 18),
        decoration: BoxDecoration(
          color: _pmBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _pmBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const SizedBox(height: 14),
            _buildSummaryBar(),
            const SizedBox(height: 14),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _buildPanel(
                      title: '결제 예정일 지남',
                      subtitle: '카드를 클릭하면 납부 기록이 저장됩니다',
                      icon: Icons.warning_amber_rounded,
                      iconColor: _pmDanger,
                      students: _overdueStudents,
                      isOverdue: true,
                      scrollController: _overdueScrollCtrl,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _buildPanel(
                      title: '결제 예정',
                      subtitle: '예정일 전 미결제 학생 목록입니다',
                      icon: Icons.schedule_rounded,
                      iconColor: const Color(0xFF1976D2),
                      students: _upcomingStudents,
                      isOverdue: false,
                      scrollController: _upcomingScrollCtrl,
                    ),
                  ),
                ],
              ),
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
  bool _processing = false;

  @override
  Widget build(BuildContext context) {
    final student = widget.studentWithInfo.student;

    final due = widget.paymentDate;
    final borderColor = widget.isOverdue
        ? _pmDanger.withOpacity(_isHovered ? 0.9 : 0.55)
        : (_isHovered ? _pmAccent : _pmBorder.withOpacity(0.9));

    return Tooltip(
      message: '결제 사이클: ${widget.cycle}번째\n결제 예정일: ${due.month}/${due.day}',
      decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(color: Colors.white, fontSize: 13),
      waitDuration: const Duration(milliseconds: 250),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: _processing ? null : () => _handlePaymentTap(context),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            decoration: BoxDecoration(
              color: _pmCardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        student.name,
                        style: const TextStyle(color: _pmText, fontSize: 15, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${due.month}/${due.day}',
                      style: const TextStyle(
                        color: _pmTextSub,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      widget.isOverdue ? '연체' : '예정',
                      style: TextStyle(
                        color: (widget.isOverdue ? _pmDanger : _pmTextSub).withOpacity(0.95),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('·', style: TextStyle(color: _pmTextSub, fontSize: 11, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Text(
                      '사이클 ${widget.cycle}',
                      style: const TextStyle(color: _pmTextSub, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    if (_processing)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: _pmAccent),
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
    if (_processing) return;
    final due = widget.paymentDate;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(due.year - 1, 1, 1),
      lastDate: DateTime(due.year + 2, 12, 31),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1B6B63),
              onPrimary: Colors.white,
              surface: Color(0xFF151C21),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF151C21),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;

    setState(() => _processing = true);
    try {
      await DataManager.instance.recordPayment(
        widget.studentWithInfo.student.id,
        widget.cycle,
        picked,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${widget.studentWithInfo.student.name} 학생의 수강료 납부를 기록했습니다.'),
          backgroundColor: _pmAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('수강료 납부 기록 실패: $e'),
            backgroundColor: const Color(0xFFE53E3E),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _processPayment() async {
    final now = DateTime.now();
    await DataManager.instance.recordPayment(
      widget.studentWithInfo.student.id,
      widget.cycle,
      now,
    );
  }
}