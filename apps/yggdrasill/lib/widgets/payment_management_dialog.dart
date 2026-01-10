import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/payment_record.dart';
import '../services/data_manager.dart';

const Color _pmBg = Color(0xFF0B1112);
const Color _pmPanelBg = Color(0xFF10171A);
const Color _pmCardBg = Color(0xFF15171C);
const Color _pmBorder = Color(0xFF223131);
const Color _pmText = Color(0xFFEAF2F2);
const Color _pmTextSub = Color(0xFF9FB3B3);
const Color _pmAccent = Color(0xFF33A373);
const Color _pmDanger = Color(0xFFF04747);

class _PaymentItem {
  final StudentWithInfo studentWithInfo;
  final DateTime dueDate; // date-only (local)
  final int cycle;
  final DateTime? paidDate; // date-only (local)

  const _PaymentItem({
    required this.studentWithInfo,
    required this.dueDate,
    required this.cycle,
    required this.paidDate,
  });

  bool get isPaid => paidDate != null;
}

class PaymentManagementDialog extends StatefulWidget {
  final VoidCallback? onClose;
  
  const PaymentManagementDialog({super.key, this.onClose});

  @override
  State<PaymentManagementDialog> createState() => _PaymentManagementDialogState();
}

class _PaymentManagementDialogState extends State<PaymentManagementDialog> {
  List<_PaymentItem> _unpaidStudents = []; // 결제 예정일 지남(미납)
  List<_PaymentItem> _upcomingStudents = []; // 결제 예정(미래/오늘)
  List<_PaymentItem> _paidInRangeStudents = []; // 기간 내(해당 기간의 모든 항목이) 완료
  int _totalCount = 0;
  bool _didNotifyClosed = false;
  late final ScrollController _overdueScrollCtrl;
  late final ScrollController _upcomingScrollCtrl;
  late final ScrollController _paidListScrollCtrl;
  late DateTime _queryStart; // date-only
  late DateTime _queryEnd; // date-only

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static int _monthsBetween(DateTime a, DateTime b) =>
      (b.year - a.year) * 12 + (b.month - a.month);

  // Supabase(add_months_eom)와 동일한 규칙:
  // - 목표 월에 원래 일이 존재하면 그대로
  // - 존재하지 않으면 다음 달 1일로 이동
  static DateTime _addMonthsEom(DateTime base, int deltaMonths) {
    final b = _dateOnly(base);
    final int vYear = b.year;
    final int vMonth = b.month;
    final int vDay = b.day;

    int tYear = vYear + ((vMonth - 1 + deltaMonths) ~/ 12);
    int tMonth = ((vMonth - 1 + deltaMonths) % 12) + 1;
    if (tMonth <= 0) {
      // Dart %는 음수에서 음수 결과가 나올 수 있어 보정
      tMonth += 12;
      tYear -= 1;
    }

    final int daysInTarget = DateUtils.getDaysInMonth(tYear, tMonth);
    if (vDay <= daysInTarget) {
      return DateTime(tYear, tMonth, vDay);
    }
    // 다음 달 1일
    tYear = tYear + (tMonth ~/ 12);
    tMonth = (tMonth % 12) + 1;
    return DateTime(tYear, tMonth, 1);
  }

  @override
  void initState() {
    super.initState();
    _overdueScrollCtrl = ScrollController();
    _upcomingScrollCtrl = ScrollController();
    _paidListScrollCtrl = ScrollController();
    final now = DateTime.now();
    final today = _dateOnly(now);
    // 기본: 이번달(1일~말일)
    _queryStart = DateTime(today.year, today.month, 1);
    _queryEnd = DateTime(today.year, today.month + 1, 0);
    _loadPaymentData();
    DataManager.instance.paymentRecordsNotifier.addListener(_loadPaymentData);
    DataManager.instance.studentChargePointsRevision.addListener(_loadPaymentData);
  }

  void _loadPaymentData() {
    if (!mounted) return;
    final now = DateTime.now();
    final today = _dateOnly(now);
    final start = _dateOnly(_queryStart);
    final end = _dateOnly(_queryEnd);

    final students = DataManager.instance.students;
    final unpaid = <_PaymentItem>[];
    final upcoming = <_PaymentItem>[];
    final paidAll = <_PaymentItem>[];

    for (final studentWithInfo in students) {
      final reg0 = studentWithInfo.basicInfo.registrationDate;
      if (reg0 == null) continue;
      final reg = _dateOnly(reg0);

      // 범위가 등록월보다 완전히 과거면 스킵
      if (end.isBefore(DateTime(reg.year, reg.month, 1))) {
        continue;
      }

      final records = DataManager.instance.getPaymentRecordsForStudent(studentWithInfo.student.id);
      final recordsSorted = List<PaymentRecord>.from(records)
        ..sort((a, b) => a.cycle.compareTo(b.cycle));
      final byCycle = <int, PaymentRecord>{
        for (final r in recordsSorted) r.cycle: r,
      };

      // ✅ 휴원/차감포인트 기반 “유효 납부일” 반영:
      // student_charge_points.next_due_datetime이 있으면 해당 날짜를 (cycle+1)의 due_date로 간주한다.
      // (월납도 session-like로 휴원 영향을 반영하는 요구사항)
      final cps = DataManager.instance.studentChargePoints
          .where((c) =>
              c.studentId == studentWithInfo.student.id &&
              c.nextDueDateTime != null)
          .toList()
        ..sort((a, b) => b.cycle.compareTo(a.cycle));
      final Map<int, DateTime> dueOverrides = <int, DateTime>{};
      if (cps.isNotEmpty) {
        final cp = cps.first;
        final eff = _dateOnly(cp.nextDueDateTime!);
        final targetCycle = (cp.cycle + 1);
        if (targetCycle >= 1) {
          dueOverrides[targetCycle] = eff;
        }
      }

      DateTime resolveDueDateForCycle(int cycle) {
        final override = dueOverrides[cycle];
        if (override != null) return override;
        final direct = byCycle[cycle];
        if (direct != null) return _dateOnly(direct.dueDate);

        PaymentRecord? base;
        for (final r in recordsSorted) {
          if (r.cycle > cycle) break;
          base = r;
        }
        if (base != null) {
          return _addMonthsEom(_dateOnly(base!.dueDate), cycle - base!.cycle);
        }
        // record가 하나도 없으면 registration_date를 cycle1 due로 가정
        return _addMonthsEom(reg, cycle - 1);
      }

      // 대략적인 cycle 범위(월 단위) + 여유 버퍼
      final approxStartCycle = _monthsBetween(reg, start) + 1;
      final approxEndCycle = _monthsBetween(reg, end) + 1;
      int minCycle = (approxStartCycle < approxEndCycle ? approxStartCycle : approxEndCycle) - 6;
      int maxCycle = (approxStartCycle > approxEndCycle ? approxStartCycle : approxEndCycle) + 6;
      if (minCycle < 1) minCycle = 1;
      if (maxCycle < 1) continue;

      final candidateCycles = <int>{};
      for (int c = minCycle; c <= maxCycle; c++) {
        candidateCycles.add(c);
      }
      // ✅ 예외 케이스: 연기(postpone) 등으로 due_date가 크게 이동한 레코드는 실제 due_date 범위로 보강
      for (final r in recordsSorted) {
        final d = _dateOnly(r.dueDate);
        if (!d.isBefore(start) && !d.isAfter(end)) {
          candidateCycles.add(r.cycle);
        }
      }

      final items = <_PaymentItem>[];
      for (final cycle in candidateCycles) {
        if (cycle < 1) continue;
        final due = resolveDueDateForCycle(cycle);
        if (due.isBefore(start) || due.isAfter(end)) continue;
        final rec = byCycle[cycle];
        items.add(_PaymentItem(
          studentWithInfo: studentWithInfo,
          dueDate: due,
          cycle: cycle,
          paidDate: rec?.paidDate == null ? null : _dateOnly(rec!.paidDate!),
        ));
      }
      if (items.isEmpty) continue;

      final unpaidItems = items.where((i) => !i.isPaid).toList();
      if (unpaidItems.isNotEmpty) {
        final pastDue = unpaidItems.where((i) => i.dueDate.isBefore(today)).toList();
        if (pastDue.isNotEmpty) {
          pastDue.sort((a, b) => b.dueDate.compareTo(a.dueDate)); // 최근(가까운 과거) 먼저
          unpaid.add(pastDue.first);
        } else {
          unpaidItems.sort((a, b) => a.dueDate.compareTo(b.dueDate)); // 가까운 미래 먼저
          upcoming.add(unpaidItems.first);
        }
        continue;
      }

      // 기간 내 모든 항목이 paid
      // 완료명단 정렬 기준을 "실제 결제일"로 맞추기 위해,
      // 학생 대표 아이템도 기간 내 가장 최근 paidDate 기준으로 선택한다.
      items.sort((a, b) => (b.paidDate ?? b.dueDate).compareTo(a.paidDate ?? a.dueDate));
      paidAll.add(items.first);
    }

    // ✅ 정렬 규칙
    // - 미납(과거): 최근(가까운 과거) → 과거
    // - 예정(미래/오늘): 최근(가까운 미래) → 미래
    unpaid.sort((a, b) => b.dueDate.compareTo(a.dueDate));
    upcoming.sort((a, b) => a.dueDate.compareTo(b.dueDate));
    paidAll.sort((a, b) => (b.paidDate ?? b.dueDate).compareTo(a.paidDate ?? a.dueDate));

    setState(() {
      _unpaidStudents = unpaid;
      _upcomingStudents = upcoming;
      _paidInRangeStudents = paidAll;
      _totalCount = unpaid.length + upcoming.length + paidAll.length;
    });
  }

  @override
  void dispose() {
    DataManager.instance.paymentRecordsNotifier.removeListener(_loadPaymentData);
    DataManager.instance.studentChargePointsRevision.removeListener(_loadPaymentData);
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

  Widget _buildPaymentStudentCard(_PaymentItem item, {required bool isUnpaid}) {
    return _PaymentStudentCard(
      studentWithInfo: item.studentWithInfo,
      paymentDate: item.dueDate,
      cycle: item.cycle,
      isOverdue: isUnpaid,
      onClose: widget.onClose,
    );
  }

  void _showPaidStudentsList() {
    String fmtYmd(DateTime d) => '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
    final paidSorted = List<_PaymentItem>.from(_paidInRangeStudents)
      ..sort((a, b) => (b.paidDate ?? b.dueDate).compareTo(a.paidDate ?? a.dueDate));
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: _pmBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          insetPadding: const EdgeInsets.all(24),
          child: Container(
            width: 576,
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
                        '기간 내 결제 완료 명단',
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '기간: ${fmtYmd(_queryStart)} ~ ${fmtYmd(_queryEnd)}',
                    style: const TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 10),
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
                  child: paidSorted.isEmpty
                      ? const Center(
                          child: Text('완료된 결제가 없습니다.', style: TextStyle(color: Colors.white24, fontSize: 13)),
                        )
                      : Scrollbar(
                          thumbVisibility: true,
                          controller: _paidListScrollCtrl,
                          child: ListView.separated(
                            controller: _paidListScrollCtrl,
                            primary: false,
                            itemCount: paidSorted.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final it = paidSorted[index];
                              final student = it.studentWithInfo.student;
                              final paymentDate = it.dueDate;
                              final paid = it.paidDate;

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
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          Positioned(
            right: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
          const Text('요약', style: TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          metric('미납', _unpaidStudents.length, _pmDanger),
          const SizedBox(width: 10),
          const Text('·', style: TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          metric('예정', _upcomingStudents.length, const Color(0xFF1976D2)),
          const SizedBox(width: 10),
          const Text('·', style: TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          metric('완료', _paidInRangeStudents.length, _pmAccent),
          const Spacer(),
          Text(
            '납부 ${_paidInRangeStudents.length}/${_totalCount}',
            style: const TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _paidInRangeStudents.isEmpty ? null : _showPaidStudentsList,
            icon: const Icon(Icons.list_alt, size: 18),
            label: const Text('완료 명단'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: _pmBorder),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
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
    required List<_PaymentItem> items,
    required bool isUnpaid,
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
                  color: Colors.transparent,
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
                      '$title (${items.length}명)',
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
            child: items.isEmpty
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
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        return _buildPaymentStudentCard(items[index], isUnpaid: isUnpaid);
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 1176,
        height: 720,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              const SizedBox(height: 10),
              _QueryRangeDropdown(
                start: _queryStart,
                end: _queryEnd,
                onChanged: (nextStart, nextEnd) {
                  _queryStart = nextStart;
                  _queryEnd = nextEnd;
                  _loadPaymentData();
                },
              ),
              const SizedBox(height: 8),
              const Divider(height: 1, color: _pmBorder),
              const SizedBox(height: 14),
              _buildSummaryBar(),
              const SizedBox(height: 14),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _buildPanel(
                        title: '예정일 지남',
                        subtitle: '카드를 클릭하면 납부 기록이 저장됩니다',
                        icon: Icons.error_outline_rounded,
                        iconColor: _pmDanger,
                        items: _unpaidStudents,
                        isUnpaid: true,
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
                        items: _upcomingStudents,
                        isUnpaid: false,
                        scrollController: _upcomingScrollCtrl,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
      message: '결제 회차: ${widget.cycle}회차\n결제 예정일: ${due.month}/${due.day}',
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
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
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
                        style: const TextStyle(color: _pmText, fontSize: 17, fontWeight: FontWeight.w800),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${due.month}/${due.day}',
                      style: const TextStyle(
                        color: _pmTextSub,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      widget.isOverdue ? '미납' : '예정',
                      style: TextStyle(
                        color: (widget.isOverdue ? _pmDanger : _pmTextSub).withOpacity(0.95),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('·', style: TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Text(
                      '${widget.cycle}회차',
                      style: const TextStyle(color: _pmTextSub, fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    if (_processing)
                      const SizedBox(
                        width: 16,
                        height: 16,
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

enum _QueryRangePreset {
  thisMonth,
  next30Days,
  last30Days,
  last3Months,
  all,
}

class _QueryRangeDropdown extends StatelessWidget {
  final DateTime start; // date-only
  final DateTime end; // date-only
  final void Function(DateTime nextStart, DateTime nextEnd) onChanged;

  const _QueryRangeDropdown({
    required this.start,
    required this.end,
    required this.onChanged,
  });

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _pretty(DateTime d) => '${d.year}. ${d.month}. ${d.day}.';

  static DateTime _shiftMonthsClamped(DateTime base, int deltaMonths) {
    int y = base.year;
    int m = base.month + deltaMonths;
    while (m <= 0) {
      m += 12;
      y -= 1;
    }
    while (m > 12) {
      m -= 12;
      y += 1;
    }
    final int lastDay = DateUtils.getDaysInMonth(y, m);
    final int d = base.day > lastDay ? lastDay : base.day;
    return DateTime(y, m, d);
  }

  static DateTime _endOfMonth(DateTime d) => DateTime(d.year, d.month + 1, 0);

  Future<DateTime?> _pick(
    BuildContext context, {
    required DateTime initial,
    required DateTime first,
    required DateTime last,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      locale: const Locale('ko', 'KR'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1B6B63),
              onPrimary: Colors.white,
              surface: Color(0xFF0B1112),
              onSurface: Color(0xFFEAF2F2),
            ),
            dialogBackgroundColor: const Color(0xFF0B1112),
          ),
          child: child!,
        );
      },
    );
    return picked == null ? null : _dateOnly(picked);
  }

  @override
  Widget build(BuildContext context) {
    const border = Color(0xFF223131);
    const bg = Color(0xFF151C21);
    const text = Color(0xFFEAF2F2);
    const sub = Color(0xFF9FB3B3);

    final DateTime s = _dateOnly(start);
    final DateTime e = _dateOnly(end);
    final DateTime today = _dateOnly(DateTime.now());
    final DateTime first = DateTime(today.year - 5, 1, 1);
    final DateTime last = DateTime(today.year + 5, 12, 31);

    Widget dateCell({
      required String value,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value,
                      style: const TextStyle(color: text, fontSize: 16, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.calendar_month, color: sub, size: 20),
                ],
              ),
            ),
          ),
        ),
      );
    }

    PopupMenuItem<_QueryRangePreset> item(_QueryRangePreset preset, String label) {
      return PopupMenuItem<_QueryRangePreset>(
        value: preset,
        child: Text(
          label,
          style: const TextStyle(color: text, fontSize: 14, fontWeight: FontWeight.w700),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: 1),
      ),
      child: Row(
        children: [
          dateCell(
            value: _pretty(s),
            onTap: () async {
              final picked = await _pick(context, initial: s, first: first, last: last);
              if (picked == null) return;
              final nextStart = picked;
              final nextEnd = nextStart.isAfter(e) ? nextStart : e;
              onChanged(nextStart, nextEnd);
            },
          ),
          Container(width: 1, height: 42, color: border.withOpacity(0.7)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text('~', style: TextStyle(color: sub, fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          Container(width: 1, height: 42, color: border.withOpacity(0.7)),
          dateCell(
            value: _pretty(e),
            onTap: () async {
              final picked = await _pick(context, initial: e, first: first, last: last);
              if (picked == null) return;
              final nextEnd = picked;
              final nextStart = nextEnd.isBefore(s) ? nextEnd : s;
              onChanged(nextStart, nextEnd);
            },
          ),
          Container(width: 1, height: 42, color: border.withOpacity(0.7)),
          SizedBox(
            width: 160,
            child: PopupMenuButton<_QueryRangePreset>(
              tooltip: '기간 프리셋',
              color: const Color(0xFF0B1112),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: border.withOpacity(0.9), width: 1),
              ),
              itemBuilder: (context) => [
                item(_QueryRangePreset.thisMonth, '이번달'),
                item(_QueryRangePreset.next30Days, '앞으로 30일'),
                item(_QueryRangePreset.last30Days, '최근 30일'),
                item(_QueryRangePreset.last3Months, '최근 3개월'),
                item(_QueryRangePreset.all, '전체'),
              ],
              onSelected: (preset) {
                DateTime nextStart = s;
                DateTime nextEnd = e;
                switch (preset) {
                  case _QueryRangePreset.thisMonth:
                    nextStart = DateTime(today.year, today.month, 1);
                    nextEnd = _endOfMonth(today);
                    break;
                  case _QueryRangePreset.next30Days:
                    nextStart = today;
                    nextEnd = today.add(const Duration(days: 29));
                    break;
                  case _QueryRangePreset.last30Days:
                    nextEnd = today;
                    nextStart = today.subtract(const Duration(days: 29));
                    break;
                  case _QueryRangePreset.last3Months:
                    nextEnd = _endOfMonth(today);
                    nextStart = _shiftMonthsClamped(today, -3);
                    break;
                  case _QueryRangePreset.all:
                    nextStart = first;
                    nextEnd = last;
                    break;
                }
                if (nextStart.isAfter(nextEnd)) {
                  final t = nextStart;
                  nextStart = nextEnd;
                  nextEnd = t;
                }
                if (nextStart.isBefore(first)) nextStart = first;
                if (nextEnd.isAfter(last)) nextEnd = last;
                onChanged(_dateOnly(nextStart), _dateOnly(nextEnd));
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '프리셋',
                        style: TextStyle(color: text, fontSize: 15, fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.arrow_drop_down, color: sub, size: 22),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}