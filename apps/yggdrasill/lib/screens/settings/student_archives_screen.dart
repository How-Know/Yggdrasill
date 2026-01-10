import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/data_manager.dart';

import '../../services/tenant_service.dart';

class StudentArchivesScreen extends StatefulWidget {
  const StudentArchivesScreen({super.key});

  @override
  State<StudentArchivesScreen> createState() => _StudentArchivesScreenState();
}

class _StudentArchivesScreenState extends State<StudentArchivesScreen> {
  late Future<List<_StudentArchiveMeta>> _future;
  final TextEditingController _searchController = TextEditingController();
  String _searchText = '';
  _ArchiveRangePreset _rangePreset = _ArchiveRangePreset.all;
  DateTimeRange? _customRange;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<_StudentArchiveMeta>> _load() async {
    final academyId = (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();
    final supa = Supabase.instance.client;

    var q = supa
        .from('student_archives')
        .select('id,student_id,student_name,archived_at,purge_after')
        .eq('academy_id', academyId);

    final range = _effectiveRange();
    if (range != null) {
      // archived_at >= startOfDay AND archived_at < endExclusive
      final start = _startOfDay(range.start);
      final endExclusive = _startOfDay(range.end).add(const Duration(days: 1));
      q = q.gte('archived_at', start.toUtc().toIso8601String());
      q = q.lt('archived_at', endExclusive.toUtc().toIso8601String());
    }

    final text = _searchText.trim();
    if (text.isNotEmpty) {
      // 학생 이름 검색 (server-side)
      q = q.ilike('student_name', '%$text%');
    }

    final rows = await q.order('archived_at', ascending: false).limit(300);

    return (rows as List)
        .map((m) => _StudentArchiveMeta.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<Map<String, dynamic>> _loadPayload(String archiveId) async {
    final supa = Supabase.instance.client;
    final row = await supa
        .from('student_archives')
        .select('payload')
        .eq('id', archiveId)
        .maybeSingle();
    if (row == null) return {};
    final payload = row['payload'];
    if (payload is Map) return Map<String, dynamic>.from(payload);
    return {'payload': payload};
  }

  Future<bool> _studentExistsOnServer({
    required String academyId,
    required String studentId,
  }) async {
    final supa = Supabase.instance.client;
    final row = await supa
        .from('students')
        .select('id')
        .eq('academy_id', academyId)
        .eq('id', studentId)
        .maybeSingle();
    return row != null;
  }

  Future<void> _restoreArchive(_StudentArchiveMeta meta) async {
    final academyId = (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();

    final exists = await _studentExistsOnServer(
      academyId: academyId,
      studentId: meta.studentId,
    );

    bool includeHistory = false;
    bool deleteArchiveAfter = false;

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF18181A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            meta.studentName.isNotEmpty ? '${meta.studentName} 복원' : '학생 복원',
            style: const TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (exists)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Text(
                      '⚠️ 동일한 학생 ID가 이미 존재합니다.\n복원 시 학생/기본정보/결제정보/시간표가 덮어써질 수 있습니다.',
                      style: TextStyle(color: Color(0xFFFFC107), height: 1.35),
                    ),
                  ),
                const Text(
                  '기본 복원 항목: 학생 정보 · 기본 정보 · 결제 정보 · 수업시간(시간표)',
                  style: TextStyle(color: Colors.white70, height: 1.35),
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  value: includeHistory,
                  onChanged: (v) => setLocal(() => includeHistory = v ?? false),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('출석/결제/보강 기록까지 복원', style: TextStyle(color: Colors.white)),
                  subtitle: const Text(
                    '데이터가 많으면 시간이 오래 걸릴 수 있습니다. (권장: 필요할 때만)',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                CheckboxListTile(
                  value: deleteArchiveAfter,
                  onChanged: (v) => setLocal(() => deleteArchiveAfter = v ?? false),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('복원 후 아카이브에서 제거', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('복원'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF18181A),
        content: SizedBox(
          width: 320,
          child: Row(
            children: [
              CircularProgressIndicator(color: Color(0xFF1976D2)),
              SizedBox(width: 16),
              Text('복원 중...', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
    );

    try {
      final payload = await _loadPayload(meta.id);
      final supa = Supabase.instance.client;

      Map<String, dynamic>? asMap(dynamic v) {
        if (v is Map) return Map<String, dynamic>.from(v);
        return null;
      }

      List<Map<String, dynamic>> asListOfMaps(dynamic v) {
        if (v is List) {
          return v
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }
        return const [];
      }

      final studentRow = asMap(payload['students']);
      if (studentRow == null) {
        throw Exception('payload.students가 비어있습니다.');
      }
      studentRow['academy_id'] = academyId;
      // students upsert (PK id)
      await supa.from('students').upsert(studentRow, onConflict: 'id');

      final basicInfoRow = asMap(payload['student_basic_info']);
      if (basicInfoRow != null) {
        basicInfoRow['academy_id'] = academyId;
        basicInfoRow['student_id'] = meta.studentId;
        await supa
            .from('student_basic_info')
            .upsert(basicInfoRow, onConflict: 'student_id');
      }

      final paymentInfoRow = asMap(payload['student_payment_info']);
      if (paymentInfoRow != null) {
        paymentInfoRow['academy_id'] = academyId;
        paymentInfoRow['student_id'] = meta.studentId;
        await supa
            .from('student_payment_info')
            .upsert(paymentInfoRow, onConflict: 'student_id');
      }

      // 시간표는 "복원 스냅샷 그대로"가 의도이므로, 기존 값은 제거 후 재삽입
      final timeBlocks = asListOfMaps(payload['student_time_blocks']);
      await supa
          .from('student_time_blocks')
          .delete()
          .eq('academy_id', academyId)
          .eq('student_id', meta.studentId);
      if (timeBlocks.isNotEmpty) {
        final rows = [
          for (final r in timeBlocks)
            {
              ...r,
              'academy_id': academyId,
              'student_id': meta.studentId,
            }
        ];
        // upsert by id (safe if ids already exist)
        await supa.from('student_time_blocks').upsert(rows, onConflict: 'id');
      }

      if (includeHistory) {
        Future<void> upsertChunked(
          String table,
          List<Map<String, dynamic>> rows, {
          required String onConflict,
        }) async {
          const chunk = 200;
          for (int i = 0; i < rows.length; i += chunk) {
            final part = rows.sublist(i, (i + chunk).clamp(0, rows.length));
            await supa.from(table).upsert(part, onConflict: onConflict);
          }
        }

        // ✅ 중요: FK 의존성이 있는 테이블은 실패해도 다른 기록 복원을 막지 않도록 분리 처리
        final List<String> historyErrors = [];
        Future<void> tryStep(String label, Future<void> Function() fn) async {
          try {
            await fn();
          } catch (e) {
            historyErrors.add('$label: $e');
          }
        }

        // 1) 납부 기록 먼저 (다른 FK에 거의 영향 없음)
        final payments = asListOfMaps(payload['payment_records']);
        await tryStep('납부 기록', () async {
          if (payments.isEmpty) return;
          final rows = [
            for (final r in payments)
              {
                ...r,
                'academy_id': academyId,
                'student_id': meta.studentId,
              }
          ];
          await upsertChunked('payment_records', rows, onConflict: 'id');
        });

        // 2) 보강/예외 기록
        final overrides = asListOfMaps(payload['session_overrides']);
        await tryStep('보강 기록', () async {
          if (overrides.isEmpty) return;

          // occurrence_id FK가 있을 수 있으나, 구버전 아카이브에는 lesson_occurrences가 없을 수 있음
          final hasOccurrencesInPayload = payload.containsKey('lesson_occurrences');
          final rows = [
            for (final r in overrides)
              {
                ...r,
                'academy_id': academyId,
                'student_id': meta.studentId,
                'occurrence_id': hasOccurrencesInPayload ? r['occurrence_id'] : null,
              }
          ];
          await upsertChunked('session_overrides', rows, onConflict: 'id');
        });

        // 3) 출석 기록 (snapshot_id / batch_session_id FK 때문에 실패 가능)
        final attendance = asListOfMaps(payload['attendance_records']);
        await tryStep('출석 기록', () async {
          if (attendance.isEmpty) return;

          // 현재 아카이브 payload에는 lesson_snapshot_headers/lesson_batch_sessions가 포함되지 않을 수 있음.
          // 포함되지 않은 경우 FK 에러 방지를 위해 snapshot_id/batch_session_id를 안전하게 null 처리한다.
          final hasSnapshotsInPayload = payload.containsKey('lesson_snapshot_headers');
          final hasBatchSessionsInPayload = payload.containsKey('lesson_batch_sessions');
          final hasOccurrencesInPayload = payload.containsKey('lesson_occurrences');

          final rows = [
            for (final r in attendance)
              {
                ...r,
                'academy_id': academyId,
                'student_id': meta.studentId,
                'snapshot_id': hasSnapshotsInPayload ? r['snapshot_id'] : null,
                'batch_session_id':
                    hasBatchSessionsInPayload ? r['batch_session_id'] : null,
                'occurrence_id': hasOccurrencesInPayload ? r['occurrence_id'] : null,
              }
          ];
          await upsertChunked('attendance_records', rows, onConflict: 'id');
        });

        if (historyErrors.isNotEmpty) {
          // 복원은 계속 진행되었지만 일부 기록은 누락될 수 있음.
          print('[WARN][StudentArchives] history restore partial errors:\n${historyErrors.join('\n')}');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '일부 기록 복원에 실패했습니다. (납부/보강은 복원됨)\n'
                  '${historyErrors.first}',
                ),
                backgroundColor: const Color(0xFFB74C4C),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        }
      }

      if (deleteArchiveAfter) {
        await supa
            .from('student_archives')
            .delete()
            .eq('academy_id', academyId)
            .eq('id', meta.id);
      }

      // 앱 메모리도 최신화(가능한 범위 내)
      try {
        await DataManager.instance.loadStudents();
        await DataManager.instance.loadStudentTimeBlocks();
      } catch (_) {}

      if (!mounted) return;
      Navigator.of(context).pop(); // progress
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(meta.studentName.isNotEmpty
              ? '${meta.studentName} 복원 완료'
              : '복원 완료'),
          backgroundColor: const Color(0xFF1976D2),
        ),
      );
      setState(() {
        _future = _load();
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // progress
      final s = e.toString();
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF18181A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('복원 실패', style: TextStyle(color: Colors.white)),
          content: Text(
            s.contains('student_archives')
                ? '아카이브 테이블/마이그레이션이 아직 적용되지 않았습니다.\n\n$s'
                : s,
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('확인', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _showDetails(_StudentArchiveMeta meta) async {
    try {
      final payload = await _loadPayload(meta.id);
      if (!mounted) return;
      final pretty = const JsonEncoder.withIndent('  ').convert(payload);
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF18181A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            meta.studentName.isNotEmpty ? meta.studentName : '아카이브 상세',
            style: const TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 980,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '아카이브 시각: ${_fmtDateTime(meta.archivedAt)}   ·   만료(삭제 예정): ${_fmtDateTime(meta.purgeAfter)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 520),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F1F1F),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF2E3338)),
                    ),
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          pretty,
                          style: const TextStyle(
                            color: Color(0xFFEAF2F2),
                            fontSize: 12,
                            height: 1.35,
                            fontFamily: 'RobotoMono',
                          ),
                        ),
                      ),
                    ),
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
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF18181A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('아카이브 로드 실패', style: TextStyle(color: Colors.white)),
          content: Text(
            s.contains('student_archives')
                ? '아카이브 테이블/마이그레이션이 아직 적용되지 않았습니다.\n\n$s'
                : s,
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('확인', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );
    }
  }

  static String _fmtDateTime(DateTime? dt) {
    if (dt == null) return '-';
    return DateFormat('yyyy.MM.dd HH:mm').format(dt.toLocal());
  }

  static DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTimeRange? _effectiveRange() {
    final now = DateTime.now();
    switch (_rangePreset) {
      case _ArchiveRangePreset.all:
        return null;
      case _ArchiveRangePreset.week:
        return DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now);
      case _ArchiveRangePreset.month1:
        return DateTimeRange(start: DateTime(now.year, now.month - 1, now.day), end: now);
      case _ArchiveRangePreset.month3:
        return DateTimeRange(start: DateTime(now.year, now.month - 3, now.day), end: now);
      case _ArchiveRangePreset.month6:
        return DateTimeRange(start: DateTime(now.year, now.month - 6, now.day), end: now);
      case _ArchiveRangePreset.year1:
        return DateTimeRange(start: DateTime(now.year - 1, now.month, now.day), end: now);
      case _ArchiveRangePreset.custom:
        return _customRange;
    }
  }

  static String _rangeLabel(_ArchiveRangePreset p) {
    switch (p) {
      case _ArchiveRangePreset.all:
        return '전체';
      case _ArchiveRangePreset.week:
        return '최근 1주';
      case _ArchiveRangePreset.month1:
        return '최근 1개월';
      case _ArchiveRangePreset.month3:
        return '최근 3개월';
      case _ArchiveRangePreset.month6:
        return '최근 6개월';
      case _ArchiveRangePreset.year1:
        return '최근 1년';
      case _ArchiveRangePreset.custom:
        return '사용자 지정';
    }
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final initial = _customRange ??
        DateTimeRange(start: now.subtract(const Duration(days: 30)), end: now);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2018, 1, 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: initial,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1976D2),
              surface: Color(0xFF18181A),
            ),
            dialogBackgroundColor: const Color(0xFF18181A),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    setState(() {
      _customRange = picked;
      _rangePreset = _ArchiveRangePreset.custom;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF18181A),
        foregroundColor: Colors.white,
        title: const Text('학생 아카이브'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: () {
              setState(() {
                _future = _load();
              });
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<List<_StudentArchiveMeta>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFF1976D2)),
            );
          }
          if (snapshot.hasError) {
            final s = snapshot.error.toString();
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Text(
                  s.contains('student_archives')
                      ? '아카이브 테이블/마이그레이션이 아직 적용되지 않았습니다.\n\n$s'
                      : s,
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final items = snapshot.data ?? const [];
          if (items.isEmpty) {
            return Column(
              children: [
                _buildTopControls(count: 0),
                const Expanded(
                  child: Center(
                    child: Text('아카이브된 학생이 없습니다.',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              _buildTopControls(count: items.length),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final meta = items[i];
                    return InkWell(
                      onTap: () => _showDetails(meta),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF15171C),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF2E3338)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.inventory_2_outlined, color: Colors.white70, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    meta.studentName.isNotEmpty ? meta.studentName : '(이름 없음)',
                                    style: const TextStyle(
                                      color: Color(0xFFEAF2F2),
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '아카이브: ${_fmtDateTime(meta.archivedAt)}   ·   만료: ${_fmtDateTime(meta.purgeAfter)}',
                                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: '복원',
                              onPressed: () => _restoreArchive(meta),
                              icon: const Icon(Icons.restore_rounded, color: Colors.white70),
                              splashRadius: 18,
                            ),
                            const SizedBox(width: 2),
                            const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTopControls({required int count}) {
    final range = _effectiveRange();
    final rangeText = range == null
        ? _rangeLabel(_rangePreset)
        : '${DateFormat('yyyy.MM.dd').format(range.start)} ~ ${DateFormat('yyyy.MM.dd').format(range.end)}';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF1F1F1F),
        border: Border(
          bottom: BorderSide(color: Color(0xFF2E3338)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '학생 이름 검색',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: const Color(0xFF15171C),
                      prefixIcon: const Icon(Icons.search_rounded, color: Colors.white54, size: 20),
                      suffixIcon: _searchText.trim().isEmpty
                          ? null
                          : IconButton(
                              tooltip: '지우기',
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _searchText = '';
                                  _future = _load();
                                });
                              },
                              icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                              splashRadius: 18,
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0xFF2E3338)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0xFF2E3338)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0xFF1976D2)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    onChanged: (v) {
                      setState(() {
                        _searchText = v;
                        _future = _load();
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF15171C),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF2E3338)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<_ArchiveRangePreset>(
                    value: _rangePreset,
                    dropdownColor: const Color(0xFF15171C),
                    iconEnabledColor: Colors.white54,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    items: _ArchiveRangePreset.values
                        .map((p) => DropdownMenuItem(
                              value: p,
                              child: Text(_rangeLabel(p)),
                            ))
                        .toList(),
                    onChanged: (v) async {
                      if (v == null) return;
                      if (v == _ArchiveRangePreset.custom) {
                        await _pickCustomRange();
                        return;
                      }
                      setState(() {
                        _rangePreset = v;
                        _future = _load();
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '표시: $count개 · 기간: $rangeText',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _pickCustomRange,
                icon: const Icon(Icons.date_range_rounded, color: Colors.white70, size: 18),
                label: const Text('기간 선택', style: TextStyle(color: Colors.white70)),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _future = _load();
                  });
                },
                icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 18),
                label: const Text('새로고침', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StudentArchiveMeta {
  final String id;
  final String studentId;
  final String studentName;
  final DateTime? archivedAt;
  final DateTime? purgeAfter;

  _StudentArchiveMeta({
    required this.id,
    required this.studentId,
    required this.studentName,
    required this.archivedAt,
    required this.purgeAfter,
  });

  factory _StudentArchiveMeta.fromMap(Map<String, dynamic> m) {
    DateTime? parseDt(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      return DateTime.tryParse(v.toString());
    }

    return _StudentArchiveMeta(
      id: (m['id'] ?? '').toString(),
      studentId: (m['student_id'] ?? '').toString(),
      studentName: (m['student_name'] ?? '').toString(),
      archivedAt: parseDt(m['archived_at']),
      purgeAfter: parseDt(m['purge_after']),
    );
  }
}

enum _ArchiveRangePreset {
  all,
  week,
  month1,
  month3,
  month6,
  year1,
  custom,
}

