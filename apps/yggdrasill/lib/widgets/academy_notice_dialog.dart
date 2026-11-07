import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/tenant_service.dart';
import 'app_snackbar.dart';
import 'dialog_tokens.dart';
import 'utility_glass_dialog_shell.dart';

Future<void> showAcademyNoticeDialog(BuildContext context) {
  return showUtilityGlassDialog(
    context: context,
    title: '공지',
    icon: Icons.campaign_rounded,
    maxWidth: 560,
    maxHeight: 680,
    preferredWidth: 520,
    child: const _AcademyNoticeDialogBody(),
  );
}

class _AcademyNotice {
  const _AcademyNotice({
    required this.id,
    required this.date,
    required this.audience,
    required this.note,
  });

  final String id;
  final DateTime date;
  final String audience;
  final String note;

  factory _AcademyNotice.fromRow(Map<String, dynamic> row) {
    final raw = '${row['closure_date'] ?? ''}';
    final parts = raw.split('-');
    final date = parts.length == 3
        ? DateTime(
            int.tryParse(parts[0]) ?? DateTime.now().year,
            int.tryParse(parts[1]) ?? 1,
            int.tryParse(parts[2]) ?? 1,
          )
        : DateTime.now();
    return _AcademyNotice(
      id: '${row['id']}',
      date: date,
      audience: '${row['audience'] ?? '전체'}'.trim(),
      note: '${row['note'] ?? ''}'.trim(),
    );
  }
}

class _AcademyNoticeDialogBody extends StatefulWidget {
  const _AcademyNoticeDialogBody();

  @override
  State<_AcademyNoticeDialogBody> createState() =>
      _AcademyNoticeDialogBodyState();
}

class _AcademyNoticeDialogBodyState extends State<_AcademyNoticeDialogBody> {
  final List<_AcademyNotice> _items = [];
  bool _loading = true;
  String? _error;
  bool _editing = false;
  String? _editingId;
  DateTime _date = DateTime.now();
  bool _confirmDelete = false;
  bool _saving = false;
  final TextEditingController _audience = TextEditingController();
  final TextEditingController _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _audience.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final academyId = await TenantService.instance.getActiveAcademyId();
    if (!mounted) return;
    if (academyId == null || academyId.isEmpty) {
      setState(() {
        _loading = false;
        _error = '학원 정보를 찾지 못했습니다.';
      });
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('academy_notices')
          .select('id, closure_date, audience, note')
          .eq('academy_id', academyId)
          .eq('kind', 'closure')
          .order('closure_date', ascending: true);
      final today = _dateOnly(DateTime.now());
      final items = (rows as List)
          .map((row) =>
              _AcademyNotice.fromRow(Map<String, dynamic>.from(row as Map)))
          .toList();
      items.sort((a, b) {
        final aPast = a.date.isBefore(today);
        final bPast = b.date.isBefore(today);
        if (aPast != bPast) return aPast ? 1 : -1;
        return aPast
            ? b.date.compareTo(a.date)
            : a.date.compareTo(b.date);
      });
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(items);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '공지를 불러오지 못했습니다.';
      });
      debugPrint('[NOTICE] $error');
    }
  }

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  String _dateLabel(DateTime date) {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return '${date.month}월 ${date.day}일 ${weekdays[date.weekday - 1]}요일';
  }

  String _heading(String audience) {
    final name = audience.trim().isEmpty ? '전체' : audience.trim();
    return name.endsWith('휴강') ? name : '$name 휴강';
  }

  String _isoDate(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  void _openCreate() {
    _audience.text = '';
    _note.text = '';
    setState(() {
      _editing = true;
      _editingId = null;
      _date = _dateOnly(DateTime.now());
      _confirmDelete = false;
    });
  }

  void _openEdit(_AcademyNotice notice) {
    _audience.text = notice.audience == '전체' ? '' : notice.audience;
    _note.text = notice.note;
    setState(() {
      _editing = true;
      _editingId = notice.id;
      _date = notice.date;
      _confirmDelete = false;
    });
  }

  void _closeEditor() {
    setState(() {
      _editing = false;
      _confirmDelete = false;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(DateTime.now().year - 1),
      lastDate: DateTime(DateTime.now().year + 2),
    );
    if (picked == null || !mounted) return;
    setState(() => _date = _dateOnly(picked));
  }

  Future<void> _save() async {
    final audience = _audience.text.trim();
    final note = _note.text.trim();
    if (audience.length > 40) {
      showAppSnackBar(context, '대상은 40자까지 적을 수 있습니다.');
      return;
    }
    if (note.length > 200) {
      showAppSnackBar(context, '안내는 200자까지 적을 수 있습니다.');
      return;
    }
    final academyId = await TenantService.instance.getActiveAcademyId();
    if (!mounted) return;
    if (academyId == null || academyId.isEmpty) {
      showAppSnackBar(context, '학원 정보를 찾지 못했습니다.');
      return;
    }
    setState(() => _saving = true);
    final patch = <String, dynamic>{
      'closure_date': _isoDate(_date),
      'audience': audience.isEmpty ? '전체' : audience,
      'note': note,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      final client = Supabase.instance.client;
      if (_editingId == null) {
        patch['academy_id'] = academyId;
        patch['kind'] = 'closure';
        await client.from('academy_notices').insert(patch);
      } else {
        await client.from('academy_notices').update(patch).eq('id', _editingId!);
      }
      if (!mounted) return;
      _closeEditor();
      await _reload();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '공지를 저장하지 못했습니다.');
      debugPrint('[NOTICE] $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final id = _editingId;
    if (id == null) return;
    if (!_confirmDelete) {
      setState(() => _confirmDelete = true);
      return;
    }
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('academy_notices').delete().eq('id', id);
      if (!mounted) return;
      _closeEditor();
      await _reload();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '공지를 지우지 못했습니다.');
      debugPrint('[NOTICE] $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) return _buildEditor();
    return _buildList();
  }

  Widget _buildList() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                '휴강',
                style: TextStyle(
                  color: kDlgText,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _openCreate,
                child: const Text(
                  '등록',
                  style: TextStyle(
                    color: kDlgAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildListBody()),
        ],
      ),
    );
  }

  Widget _buildListBody() {
    if (_loading) {
      return const Center(
        child: Text(
          '공지를 불러오는 중',
          style: TextStyle(color: kDlgTextSub, fontSize: 15),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: kDlgTextSub, fontSize: 15),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text(
          '올라온 공지가 없습니다.',
          style: TextStyle(color: kDlgTextSub, fontSize: 15),
        ),
      );
    }
    final today = _dateOnly(DateTime.now());
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(color: kDlgBorder, height: 1),
      itemBuilder: (context, index) {
        final item = _items[index];
        final past = item.date.isBefore(today);
        final titleColor = past ? kDlgTextSub : kDlgText;
        return InkWell(
          onTap: () => _openEdit(item),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  past
                      ? '${_dateLabel(item.date)} · 지남'
                      : _dateLabel(item.date),
                  style: const TextStyle(color: kDlgTextSub, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  _heading(item.audience),
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (item.note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    item.note,
                    style: const TextStyle(
                      color: kDlgTextSub,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TextButton(
                onPressed: _saving ? null : _closeEditor,
                child: const Text(
                  '목록',
                  style: TextStyle(color: kDlgTextSub, fontSize: 16),
                ),
              ),
              const Spacer(),
              Text(
                _editingId == null ? '휴강 등록' : '휴강 수정',
                style: const TextStyle(
                  color: kDlgText,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              const SizedBox(width: 64),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            '날짜',
            style: TextStyle(color: kDlgTextSub, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _fieldShell(
            onTap: _saving ? null : _pickDate,
            child: Text(
              _dateLabel(_date),
              style: const TextStyle(color: kDlgText, fontSize: 17),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            '대상',
            style: TextStyle(color: kDlgTextSub, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _fieldShell(
            child: TextField(
              controller: _audience,
              enabled: !_saving,
              maxLength: 40,
              style: const TextStyle(color: kDlgText, fontSize: 17),
              cursorColor: kDlgAccent,
              decoration: const InputDecoration(
                counterText: '',
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '비워 두면 전체',
                hintStyle: TextStyle(color: kDlgTextSub, fontSize: 17),
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            '안내',
            style: TextStyle(color: kDlgTextSub, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _fieldShell(
            child: TextField(
              controller: _note,
              enabled: !_saving,
              maxLength: 200,
              maxLines: 3,
              style: const TextStyle(color: kDlgText, fontSize: 17, height: 1.4),
              cursorColor: kDlgAccent,
              decoration: const InputDecoration(
                counterText: '',
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '선택',
                hintStyle: TextStyle(color: kDlgTextSub, fontSize: 17),
              ),
            ),
          ),
          const Spacer(),
          Row(
            children: [
              if (_editingId != null)
                TextButton(
                  onPressed: _saving ? null : _delete,
                  child: Text(
                    _confirmDelete ? '다시 누르면 삭제' : '삭제',
                    style: const TextStyle(color: kDlgTextSub, fontSize: 16),
                  ),
                ),
              const Spacer(),
              TextButton(
                onPressed: _saving ? null : _save,
                child: Text(
                  _saving ? '저장 중' : '저장',
                  style: const TextStyle(
                    color: kDlgAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fieldShell({required Widget child, VoidCallback? onTap}) {
    return Material(
      color: kDlgFieldBg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: child,
        ),
      ),
    );
  }
}
