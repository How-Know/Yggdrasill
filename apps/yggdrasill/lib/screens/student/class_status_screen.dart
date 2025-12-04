import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'components/class_status_dashboard.dart';

class ClassStatusScreen extends StatelessWidget {
  const ClassStatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1112),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: 0), // 왼쪽 여백 (AllStudentsView와 동일)
          Expanded(
            flex: 2,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Container(
                  // AllStudentsView의 메인 컨테이너 제약조건 및 스타일 적용
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
                      // 학생 탭 스타일의 헤더
                      Container(
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
                                // 뒤로가기 버튼 통합
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
                                const Icon(Icons.bar_chart_rounded, color: Colors.white70, size: 32),
                                const SizedBox(width: 16),
                                const Text(
                                  '수강 현황',
                                  style: TextStyle(
                                    color: Color(0xFFEAF2F2),
                                    fontSize: 32,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 15),
                                const Text(
                                  '출결 및 납입 통계',
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
                      ),
                      const SizedBox(height: 24),
                      // 메인 콘텐츠 영역
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B1112), // 배경색 통일
                            borderRadius: BorderRadius.circular(16),
                            // AllStudentsView는 메인 리스트에 테두리가 없거나 미미함, 여기서는 투명하게 처리하거나 제거
                          ),
                          child: const ClassStatusDashboard(isFullPage: true),
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
