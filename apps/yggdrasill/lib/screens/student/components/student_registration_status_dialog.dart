import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/student_archive_service.dart';
import '../../../services/tenant_service.dart';
import '../../../widgets/pill_tab_selector.dart';

class StudentRegistrationStatusDialog extends StatefulWidget {
  const StudentRegistrationStatusDialog({super.key});

  @override
  State<StudentRegistrationStatusDialog> createState() =>
      _StudentRegistrationStatusDialogState();
}

class _StudentRegistrationStatusDialogState
    extends State<StudentRegistrationStatusDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _searchText = '';
  _RegistrationRangePreset _rangePreset = _RegistrationRangePreset.month1;
  DateTimeRange? _customRange;
  int _tabIndex = 0; // 0: 신규, 1: 퇴원

  String? _academyId;
  bool _loading = false;
  List<_NewStudentMeta> _newStudents = const <_NewStudentMeta>[];
  List<StudentArchiveMeta> _archivedStudents = const <StudentArchiveMeta>[];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTimeRange? _effectiveRange() {
    final now = DateTime.now();
    switch (_rangePreset) {
      case _RegistrationRangePreset.week:
        return DateTimeRange(
          start: now.subtract(const Duration(days: 7)),
          end: now,
        );
      case _RegistrationRangePreset.month1:
        return DateTimeRange(
          start: DateTime(now.year, now.month - 1, now.day),
          end: now,
        );
      case _RegistrationRangePreset.month3:
        return DateTimeRange(
          start: DateTime(now.year, now.month - 3, now.day),
          end: now,
        );
      case _RegistrationRangePreset.month6:
        return DateTimeRange(
          start: DateTime(now.year, now.month - 6, now.day),
          end: now,
        );
      case _RegistrationRangePreset.year1:
        return DateTimeRange(
          start: DateTime(now.year - 1, now.month, now.day),
          end: now,
        );
      case _RegistrationRangePreset.custom:
        return _customRange;
    }
  }

  String _rangeLabel(_RegistrationRangePreset p) {
    switch (p) {
      case _RegistrationRangePreset.week:
        return '최근 1주';
      case _RegistrationRangePreset.month1:
        return '최근 1개월';
      case _RegistrationRangePreset.month3:
        return '최근 3개월';
      case _RegistrationRangePreset.month6:
        return '최근 6개월';
      case _RegistrationRangePreset.year1:
        return '최근 1년';
      case _RegistrationRangePreset.custom:
        return '사용자 지정';
    }
  }

  String _educationLevelLabel(int? value) {
    switch (value) {
      case 0:
        return '초등';
      case 1:
        return '중등';
      case 2:
        return '고등';
      default:
        return '-';
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
      _rangePreset = _RegistrationRangePreset.custom;
    });
    await _loadAll();
  }

  Future<void> _loadAll() async {
    if (_academyId == null) {
      _academyId = (await TenantService.instance.getActiveAcademyId()) ??
          await TenantService.instance.ensureActiveAcademy();
    }
    final academyId = _academyId!;
    final range = _effectiveRange();
    final text = _searchText.trim();

    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _loadNewStudents(
          academyId: academyId,
          startInclusive: range?.start,
          endInclusive: range?.end,
          searchText: text,
        ),
        StudentArchiveService.instance.loadArchives(
          academyId: academyId,
          startInclusive: range?.start,
          endInclusive: range?.end,
          searchText: text,
          limit: 300,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _newStudents = results[0] as List<_NewStudentMeta>;
        _archivedStudents = results[1] as List<StudentArchiveMeta>;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<List<_NewStudentMeta>> _loadNewStudents({
    required String academyId,
    DateTime? startInclusive,
    DateTime? endInclusive,
    required String searchText,
  }) async {
    final supa = Supabase.instance.client;
    var q = supa
        .from('students')
        .select('id,name,school,education_level,grade,created_at')
        .eq('academy_id', academyId);

    if (startInclusive != null && endInclusive != null) {
      final start = _startOfDay(startInclusive);
      final endExclusive =
          _startOfDay(endInclusive).add(const Duration(days: 1));
      q = q.gte('created_at', start.toUtc().toIso8601String());
      q = q.lt('created_at', endExclusive.toUtc().toIso8601String());
    }

    if (searchText.isNotEmpty) {
      q = q.ilike('name', '%$searchText%');
    }

    final rows = await q.order('created_at', ascending: false).limit(300);
    return (rows as List)
        .map((row) => _NewStudentMeta.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<void> _restoreArchive(StudentArchiveMeta meta) async {
    final academyId = _academyId ??
        (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();
    _academyId = academyId;

    final exists = await StudentArchiveService.instance.studentExistsOnServer(
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                      style: TextStyle(
                        color: Color(0xFFFFC107),
                        height: 1.35,
                      ),
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
                  title: const Text(
                    '출석/결제/보강 기록까지 복원',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    '데이터가 많으면 시간이 오래 걸릴 수 있습니다. (권장: 필요할 때만)',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                CheckboxListTile(
                  value: deleteArchiveAfter,
                  onChanged: (v) =>
                      setLocal(() => deleteArchiveAfter = v ?? false),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    '복원 후 아카이브에서 제거',
                    style: TextStyle(color: Colors.white),
                  ),
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
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('복원'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

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
      final result = await StudentArchiveService.instance.restoreArchive(
        academyId: academyId,
        meta: meta,
        options: StudentArchiveRestoreOptions(
          includeHistory: includeHistory,
          deleteArchiveAfter: deleteArchiveAfter,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();

      final firstError = result.historyErrors.isEmpty
          ? ''
          : '\n일부 기록 복원 실패: ${result.historyErrors.first}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            meta.studentName.isNotEmpty
                ? '${meta.studentName} 복원 완료$firstError'
                : '복원 완료$firstError',
          ),
          backgroundColor: result.hasHistoryErrors
              ? const Color(0xFFB74C4C)
              : const Color(0xFF1976D2),
        ),
      );
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      final s = e.toString();
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF18181A),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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

  String _fmtDateTime(DateTime? dt) {
    if (dt == null) return '-';
    return DateFormat('yyyy.MM.dd HH:mm').format(dt.toLocal());
  }

  Widget _buildNewStudentsList() {
    if (_newStudents.isEmpty) {
      return const Center(
        child:
            Text('기간 내 신규학생이 없습니다.', style: TextStyle(color: Colors.white70)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      itemCount: _newStudents.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final item = _newStudents[i];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF15171C),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF2E3338)),
          ),
          child: Row(
            children: [
              const Icon(Icons.person_add_alt_1_rounded,
                  color: Color(0xFF33A373), size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name.isEmpty ? '(이름 없음)' : item.name,
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
                      '${item.school.isEmpty ? '학교 미입력' : item.school} · ${_educationLevelLabel(item.educationLevel)} ${item.grade}학년',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _fmtDateTime(item.createdAt),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildArchivedStudentsList() {
    if (_archivedStudents.isEmpty) {
      return const Center(
        child:
            Text('기간 내 퇴원학생이 없습니다.', style: TextStyle(color: Colors.white70)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      itemCount: _archivedStudents.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final meta = _archivedStudents[i];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF15171C),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF2E3338)),
          ),
          child: Row(
            children: [
              const Icon(Icons.inventory_2_outlined,
                  color: Colors.white70, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.studentName.isNotEmpty
                          ? meta.studentName
                          : '(이름 없음)',
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
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => _restoreArchive(meta),
                icon: const Icon(Icons.restore_rounded, size: 16),
                label: const Text('복원'),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final range = _effectiveRange();
    final rangeText = range == null
        ? _rangeLabel(_rangePreset)
        : '${DateFormat('yyyy.MM.dd').format(range.start)} ~ ${DateFormat('yyyy.MM.dd').format(range.end)}';
    final totalText = _tabIndex == 0
        ? '신규 ${_newStudents.length}명'
        : '퇴원 ${_archivedStudents.length}명';

    return AlertDialog(
      backgroundColor: const Color(0xFF18181A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        '등록 현황',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 860,
        child: SizedBox(
          height: 620,
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
                          prefixIcon: const Icon(Icons.search_rounded,
                              color: Colors.white54, size: 20),
                          suffixIcon: _searchText.trim().isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '지우기',
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _searchText = '');
                                    _loadAll();
                                  },
                                  icon: const Icon(Icons.close_rounded,
                                      color: Colors.white54, size: 18),
                                  splashRadius: 18,
                                ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                const BorderSide(color: Color(0xFF2E3338)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                const BorderSide(color: Color(0xFF2E3338)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                const BorderSide(color: Color(0xFF1976D2)),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                        onChanged: (v) {
                          setState(() => _searchText = v);
                          _loadAll();
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
                      child: DropdownButton<_RegistrationRangePreset>(
                        value: _rangePreset,
                        dropdownColor: const Color(0xFF15171C),
                        iconEnabledColor: Colors.white54,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                        items: _RegistrationRangePreset.values
                            .map((p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(_rangeLabel(p)),
                                ))
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          if (v == _RegistrationRangePreset.custom) {
                            await _pickCustomRange();
                            return;
                          }
                          setState(() => _rangePreset = v);
                          await _loadAll();
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '새로고침',
                    onPressed: _loadAll,
                    icon: const Icon(Icons.refresh_rounded,
                        color: Colors.white70),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    '$totalText · 기간: $rangeText',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _pickCustomRange,
                    icon: const Icon(Icons.date_range_rounded,
                        color: Colors.white70, size: 18),
                    label: const Text(
                      '기간 선택',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Center(
                child: PillTabSelector(
                  selectedIndex: _tabIndex,
                  tabs: const ['신규학생', '퇴원학생'],
                  onTabSelected: (idx) => setState(() => _tabIndex = idx),
                  width: 320,
                  height: 42,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF1976D2),
                        ),
                      )
                    : (_tabIndex == 0
                        ? _buildNewStudentsList()
                        : _buildArchivedStudentsList()),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}

class _NewStudentMeta {
  final String id;
  final String name;
  final String school;
  final int grade;
  final int? educationLevel;
  final DateTime? createdAt;

  const _NewStudentMeta({
    required this.id,
    required this.name,
    required this.school,
    required this.grade,
    required this.educationLevel,
    required this.createdAt,
  });

  factory _NewStudentMeta.fromMap(Map<String, dynamic> m) {
    int asInt(dynamic v, {int fallback = 0}) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    DateTime? parseDt(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      return DateTime.tryParse(v.toString());
    }

    return _NewStudentMeta(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      school: (m['school'] ?? '').toString(),
      grade: asInt(m['grade']),
      educationLevel:
          m['education_level'] == null ? null : asInt(m['education_level']),
      createdAt: parseDt(m['created_at']),
    );
  }
}

enum _RegistrationRangePreset {
  week,
  month1,
  month3,
  month6,
  year1,
  custom,
}
