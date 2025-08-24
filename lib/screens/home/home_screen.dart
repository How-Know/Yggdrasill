import 'package:flutter/material.dart';
import '../../services/kakao_reservation_service.dart';
import '../../models/kakao_reservation.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    KakaoReservationService.instance.startPolling();
  }

  @override
  void dispose() {
    KakaoReservationService.instance.stopPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '홈',
            style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _KakaoReservationPanel(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KakaoReservationPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF18181A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '카카오 상담예약',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white70),
                tooltip: '새로고침',
                onPressed: () => KakaoReservationService.instance.fetchReservations(),
              )
            ],
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<List<KakaoReservation>>(
            valueListenable: KakaoReservationService.instance.reservationsNotifier,
            builder: (context, list, _) {
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text('새 예약이 없습니다.', style: TextStyle(color: Colors.white54)),
                );
              }
              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: list.length.clamp(0, 20),
                separatorBuilder: (_, __) => const Divider(color: Colors.white12),
                itemBuilder: (context, index) {
                  final r = list[index];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Row(
                      children: [
                        if (!r.isRead)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: const BoxDecoration(color: Color(0xFF1976D2), shape: BoxShape.circle),
                          ),
                        Expanded(
                          child: Text(
                            ((r.studentName ?? r.name ?? r.kakaoNickname ?? r.kakaoUserId ?? '무기명')) + ' · ' + _formatDateTime(r.createdAt),
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.message,
                            style: const TextStyle(color: Colors.white70, fontSize: 13),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          if (r.desiredDateTime != null || (r.phone != null && r.phone!.isNotEmpty))
                            Row(
                              children: [
                                if (r.desiredDateTime != null)
                                  Text('희망: ' + _formatDateTime(r.desiredDateTime!), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                if (r.desiredDateTime != null && r.phone != null && r.phone!.isNotEmpty)
                                  const SizedBox(width: 8),
                                if (r.phone != null && r.phone!.isNotEmpty)
                                  Text('연락처: ' + r.phone!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                              ],
                            ),
                        ],
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (r.phone != null && r.phone!.isNotEmpty) Text(r.phone!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.mark_email_read, color: Colors.white70),
                          tooltip: '읽음 처리',
                          onPressed: () => KakaoReservationService.instance.markAsRead(r.id),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                          tooltip: '삭제',
                          onPressed: () => KakaoReservationService.instance.deleteReservation(r.id),
                        )
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}



