import 'package:flutter/material.dart';
import '../../services/kakao_reservation_service.dart';
import '../../models/kakao_reservation.dart';
import '../../services/parent_link_service.dart';
import '../../models/parent_link.dart';
import '../../services/sync_service.dart';

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
              const SizedBox(width: 24),
              Expanded(
                child: _ParentLinkPanel(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KakaoReservationPanel extends StatelessWidget {
  String _formatPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 11) {
      return digits.substring(0,3) + '-' + digits.substring(3,7) + '-' + digits.substring(7);
    }
    if (digits.length == 10) {
      return digits.substring(0,3) + '-' + digits.substring(3,6) + '-' + digits.substring(6);
    }
    return raw;
  }
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
                icon: const Icon(Icons.sync, color: Colors.white70),
                tooltip: '동기화(학생/출석)',
                onPressed: () async {
                  await SyncService.instance.manualSync();
                },
              ),
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
              return SizedBox(
                height: 360,
                child: ListView.separated(
                  shrinkWrap: false,
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: list.length,
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
                            (() {
                              final dn = (r.studentName ?? r.name ?? r.kakaoNickname ?? r.kakaoUserId ?? '').trim();
                              final left = dn.isNotEmpty ? (dn + ' 학생 · ') : '';
                              return left + '신청: ' + _formatDateTime(r.createdAt);
                            })(),
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
                          if (r.desiredDateTime != null)
                            Row(
                              children: [
                                Text('상담 희망: ' + _formatDateTime(r.desiredDateTime!), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                              ],
                            ),
                        ],
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 연락처는 subtitle에서 이미 노출되므로 trailing에 중복 노출하지 않음
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
                ),
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

class _ParentLinkPanel extends StatefulWidget {
  @override
  State<_ParentLinkPanel> createState() => _ParentLinkPanelState();
}

class _ParentLinkPanelState extends State<_ParentLinkPanel> {
  bool _deleting = false;
  String? _deletingId;

  String _maskPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length >= 7) {
      final head = digits.substring(0, 3);
      final tail = digits.substring(digits.length - 4);
      return '$head-****-$tail';
    }
    return raw;
  }

  String _shortenId(String? id) {
    if (id == null || id.isEmpty) return '';
    return id.length <= 8 ? id : id.substring(0, 8) + '…';
  }

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return '';
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
  @override
  void initState() {
    super.initState();
    ParentLinkService.instance.fetchRecentLinks();
  }

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
                '카카오 출석연동(부모-번호 매칭)',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white70),
                tooltip: '새로고침',
                onPressed: () => ParentLinkService.instance.fetchRecentLinks(),
              )
            ],
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<List<ParentLink>>(
            valueListenable: ParentLinkService.instance.linksNotifier,
            builder: (context, list, _) {
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text('최근 링크 내역이 없습니다.', style: TextStyle(color: Colors.white54)),
                );
              }
              return SizedBox(
                height: 360,
                child: ListView.separated(
                  key: const Key('list-parent-links'),
                  shrinkWrap: false,
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(color: Colors.white12),
                  itemBuilder: (context, index) {
                    final p = list[index];
                    final studentTitle = ((p.matchedStudentName ?? '').isNotEmpty)
                        ? '${p.matchedStudentName} 부모님'
                        : null;
                    final idTitle = (p.kakaoUserId ?? '').isNotEmpty
                        ? _shortenId(p.kakaoUserId)
                        : '(알 수 없음)';
                    final title = studentTitle ?? idTitle;
                    final phoneMasked = _maskPhone(p.phone ?? '');
                    final status = p.status ?? '';
                    final created = _formatDateTime(p.createdAt);
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                '번호: ' + phoneMasked + (status.isNotEmpty ? ' · 상태: ' + status : '') + (created.isNotEmpty ? ' · 연결: ' + created : ''),
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      trailing: IconButton(
                        key: Key('button-delete-mapping-${p.id}'),
                        icon: (_deleting && _deletingId == p.id)
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.redAccent)))
                            : const Icon(Icons.delete_outline, color: Colors.redAccent),
                        tooltip: '삭제',
                        onPressed: (_deleting && _deletingId == p.id)
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) {
                                    return AlertDialog(
                                      key: const Key('dialog-confirm-delete'),
                                      backgroundColor: const Color(0xFF1F1F1F),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      title: const Text('매핑 삭제', style: TextStyle(color: Colors.white)),
                                      content: const Text(
                                        '정말로 이 매핑을 삭제하시겠습니까?\n삭제하면 챗봇에서 출석 조회가 불가능해집니다.',
                                        style: TextStyle(color: Colors.white70),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.of(ctx).pop(false),
                                          child: const Text('취소', style: TextStyle(color: Colors.white70)),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.of(ctx).pop(true),
                                          child: const Text('삭제', style: TextStyle(color: Color(0xFFE53E3E))),
                                        ),
                                      ],
                                    );
                                  },
                                );
                                if (confirmed != true) return;
                                setState(() { _deleting = true; _deletingId = p.id; });
                                try {
                                  final ok = await ParentLinkService.instance.deleteLink(p);
                                  if (ok) {
                                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('삭제 완료')));
                                    // 안전 동기화 (낙관적 업데이트 이후 서버 상태 재확인)
                                    await ParentLinkService.instance.fetchRecentLinks();
                                  } else {
                                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('삭제 실패')));
                                  }
                                } catch (e) {
                                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('삭제 중 오류: $e')));
                                } finally {
                                  if (mounted) setState(() { _deleting = false; _deletingId = null; });
                                }
                              },
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}



