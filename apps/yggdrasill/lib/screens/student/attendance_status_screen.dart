import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'components/attendance_status_dashboard.dart';

class AttendanceStatusScreen extends StatelessWidget {
  const AttendanceStatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1112),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: 0),
          Expanded(
            flex: 2,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Container(
                  constraints: const BoxConstraints(minWidth: 624),
                  padding: const EdgeInsets.only(left: 34, right: 24, top: 24, bottom: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B1112),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 1),
                      _buildHeader(context),
                      const SizedBox(height: 24),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B1112),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const AttendanceStatusDashboard(isFullPage: true),
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

  Widget _buildHeader(BuildContext context) {
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
              const Icon(Icons.fact_check_outlined, color: Colors.white70, size: 32),
              const SizedBox(width: 16),
              const Text(
                '출결 현황',
                style: TextStyle(
                  color: Color(0xFFEAF2F2),
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 15),
              const Text(
                '어제·오늘 출결 통계',
                style: TextStyle(
                  color: Color(0xFFCBD8D8),
                  fontSize: 18,
                ),
              ),
            ],
          ),
          Text(
            '업데이트 ${DateFormat('MM.dd').format(DateTime.now())}',
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





