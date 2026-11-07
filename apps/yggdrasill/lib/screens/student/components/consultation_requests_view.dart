import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../../../services/tenant_service.dart';
import '../../../widgets/app_snackbar.dart';

class ConsultationRequestsView extends StatefulWidget {
  const ConsultationRequestsView({super.key});

  @override
  State<ConsultationRequestsView> createState() =>
      _ConsultationRequestsViewState();
}

class _ConsultationRequest {
  const _ConsultationRequest({
    required this.id,
    required this.phone,
    required this.availableTime,
    required this.question,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String phone;
  final String availableTime;
  final String question;
  final String status;
  final DateTime createdAt;

  factory _ConsultationRequest.fromRow(Map<String, dynamic> row) {
    return _ConsultationRequest(
      id: '${row['id']}',
      phone: '${row['phone'] ?? ''}',
      availableTime: '${row['available_time'] ?? ''}',
      question: '${row['question'] ?? ''}'.trim(),
      status: '${row['status'] ?? 'new'}',
      createdAt: DateTime.tryParse('${row['created_at']}')?.toLocal() ??
          DateTime.now(),
    );
  }
}

class _ConsultationRequestsViewState extends State<ConsultationRequestsView> {
  final List<_ConsultationRequest> _items = [];
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    final channel = _channel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    super.dispose();
  }

  Future<void> _reload() async {
    final gen = ++_loadGen;
    final academyId = await TenantService.instance.getActiveAcademyId();
    if (!mounted || gen != _loadGen) return;
    if (academyId == null || academyId.isEmpty) {
      setState(() {
        _loading = false;
        _error = '학원 정보를 찾지 못했습니다.';
      });
      return;
    }
    final client = Supabase.instance.client;
    try {
      final cutoff = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 365))
          .toIso8601String();
      await client
          .from('homepage_consultation_requests')
          .delete()
          .eq('academy_id', academyId)
          .lt('completed_at', cutoff);
      final rows = await client
          .from('homepage_consultation_requests')
          .select('id, phone, available_time, question, status, created_at')
          .eq('academy_id', academyId)
          .order('created_at', ascending: false);
      final items = (rows as List)
          .map((row) => _ConsultationRequest.fromRow(
                Map<String, dynamic>.from(row as Map),
              ))
          .toList();
      items.sort((a, b) {
        final rank = _statusRank(a.status).compareTo(_statusRank(b.status));
        if (rank != 0) return rank;
        return b.createdAt.compareTo(a.createdAt);
      });
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _items
          ..clear()
          ..addAll(items);
        _loading = false;
        _error = null;
      });
      _listen(academyId);
    } catch (error) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _loading = false;
        _error = '상담 신청을 불러오지 못했습니다.';
      });
      debugPrint('[CONSULT] $error');
    }
  }

  void _listen(String academyId) {
    if (_channel != null) return;
    _channel = Supabase.instance.client
        .channel('homepage_consultations:$academyId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'homepage_consultation_requests',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'academy_id',
            value: academyId,
          ),
          callback: (_) => _reload(),
        )
        .subscribe();
  }

  int _statusRank(String status) {
    switch (status) {
      case 'new':
        return 0;
      case 'contacted':
        return 1;
      default:
        return 2;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'contacted':
        return '연락함';
      case 'done':
        return '마친 상담';
      default:
        return '새 신청';
    }
  }

  String _formatPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 11) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
    }
    if (digits.length == 10) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
    }
    return raw;
  }

  String _formatWhen(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.month}/${time.day} ${two(time.hour)}:${two(time.minute)}';
  }

  Future<void> _mark(String id, String status) async {
    final patch = <String, dynamic>{'status': status};
    final now = DateTime.now().toUtc().toIso8601String();
    if (status == 'contacted') patch['contacted_at'] = now;
    if (status == 'done') patch['completed_at'] = now;
    try {
      await Supabase.instance.client
          .from('homepage_consultation_requests')
          .update(patch)
          .eq('id', id);
      if (!mounted) return;
      showAppSnackBar(
        context,
        status == 'done'
            ? '상담을 마쳤습니다. 1년 뒤에 이 번호는 지워집니다.'
            : '연락함으로 표시했습니다.',
      );
      await _reload();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '상태를 바꾸지 못했습니다.');
      debugPrint('[CONSULT] $error');
    }
  }

  Future<void> _delete(PreviewAcademyPanelStyle style, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: style.dropdownBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              FabTabBarTokens.previewAcademyGroupedCardRadius,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '이 상담 신청을 지울까요?',
                    style: TextStyle(
                      color: style.title,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '번호도 함께 지워집니다.',
                    style: TextStyle(color: style.hint, fontSize: 15),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text('취소', style: TextStyle(color: style.hint)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(
                          '삭제',
                          style: TextStyle(color: style.changeButtonText),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    try {
      await Supabase.instance.client
          .from('homepage_consultation_requests')
          .delete()
          .eq('id', id);
      if (!mounted) return;
      showAppSnackBar(context, '상담 신청을 지웠습니다.');
      await _reload();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '상담 신청을 지우지 못했습니다.');
      debugPrint('[CONSULT] $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final style = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final decoration = PreviewAcademyGroupedFieldsCard.cardDecoration(
      style,
      brightness: brightness,
    );

    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 624),
        child: Padding(
          padding: const EdgeInsets.only(left: 34, right: 24),
          child: _loading
              ? Padding(
                  padding: const EdgeInsets.only(top: 28),
                  child: Text(
                    '상담 신청을 불러오는 중',
                    style: TextStyle(color: style.hint, fontSize: 15),
                  ),
                )
              : _error != null
                  ? Padding(
                      padding: const EdgeInsets.only(top: 28),
                      child: Text(
                        _error!,
                        style: TextStyle(color: style.hint, fontSize: 15),
                      ),
                    )
                  : _items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 28),
                          child: Text(
                            '새 상담 신청이 없습니다.',
                            style: TextStyle(color: style.hint, fontSize: 15),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(
                            top: 4,
                            bottom:
                                FabTabBarTokens.fabStyleScreenTabBarBottomPadding,
                          ),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            final phone = _formatPhone(item.phone);
                            return Container(
                              decoration: decoration,
                              padding:
                                  const EdgeInsets.fromLTRB(22, 20, 22, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          phone,
                                          style: TextStyle(
                                            color: style.title,
                                            fontSize: 20,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        _statusLabel(item.status),
                                        style: TextStyle(
                                          color: item.status == 'new'
                                              ? style.changeButtonText
                                              : style.hint,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    item.availableTime,
                                    style: TextStyle(
                                      color: style.inputText,
                                      fontSize: 15,
                                    ),
                                  ),
                                  if (item.question.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      item.question,
                                      style: TextStyle(
                                        color: style.hint,
                                        fontSize: 15,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Text(
                                        _formatWhen(item.createdAt),
                                        style: TextStyle(
                                          color: style.hint,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const Spacer(),
                                      TextButton(
                                        onPressed: () async {
                                          await Clipboard.setData(
                                            ClipboardData(text: phone),
                                          );
                                          if (!context.mounted) return;
                                          showAppSnackBar(
                                            context,
                                            '번호를 복사했습니다.',
                                          );
                                        },
                                        child: Text(
                                          '번호 복사',
                                          style: TextStyle(
                                            color: style.changeButtonText,
                                          ),
                                        ),
                                      ),
                                      if (item.status == 'new')
                                        TextButton(
                                          onPressed: () =>
                                              _mark(item.id, 'contacted'),
                                          child: Text(
                                            '연락함',
                                            style: TextStyle(
                                              color: style.changeButtonText,
                                            ),
                                          ),
                                        ),
                                      if (item.status == 'contacted')
                                        TextButton(
                                          onPressed: () =>
                                              _mark(item.id, 'done'),
                                          child: Text(
                                            '마침',
                                            style: TextStyle(
                                              color: style.changeButtonText,
                                            ),
                                          ),
                                        ),
                                      TextButton(
                                        onPressed: () =>
                                            _delete(style, item.id),
                                        child: Text(
                                          '삭제',
                                          style: TextStyle(color: style.hint),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
        ),
      ),
    );
  }
}
