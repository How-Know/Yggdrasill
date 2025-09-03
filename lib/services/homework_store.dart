import 'package:flutter/material.dart';
import 'dart:math';

enum HomeworkStatus { inProgress, completed, homework }

class HomeworkItem {
  final String id;
  String title;
  String body;
  Color color;
  HomeworkStatus status;
  int accumulatedMs; // 누적 시간(ms)
  DateTime? runStart; // 진행 중이면 시작 시각
  DateTime? completedAt;
  DateTime? firstStartedAt; // 처음 시작한 시간
  HomeworkItem({
    required this.id,
    required this.title,
    required this.body,
    this.color = const Color(0xFF1976D2),
    this.status = HomeworkStatus.inProgress,
    this.accumulatedMs = 0,
    this.runStart,
    this.completedAt,
    this.firstStartedAt,
  });
}

class HomeworkStore {
  HomeworkStore._internal();
  static final HomeworkStore instance = HomeworkStore._internal();

  final Map<String, List<HomeworkItem>> _byStudentId = {};
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  // 간단 영속화 캐시 (앱 시작 시 한번 로드, 변경 시 저장)
  bool _loaded = false;

  List<HomeworkItem> items(String studentId) {
    final list = _byStudentId[studentId] ?? const <HomeworkItem>[];
    return List<HomeworkItem>.from(list);
  }

  Future<void> loadAll() async {
    if (_loaded) return;
    try {
      final db = await AcademyDbService.instance.db;
      final rows = await db.query('homework_items');
      _byStudentId.clear();
      for (final r in rows) {
        final item = HomeworkItem(
          id: r['id'] as String,
          title: (r['title'] as String?) ?? '',
          body: (r['body'] as String?) ?? '',
          color: Color((r['color'] as int?) ?? 0xFF1976D2),
          status: HomeworkStatus.values[(r['status'] as int?) ?? 0],
          accumulatedMs: (r['accumulated_ms'] as int?) ?? 0,
          runStart: (r['run_start'] as String?) != null ? DateTime.tryParse(r['run_start'] as String) : null,
          completedAt: (r['completed_at'] as String?) != null ? DateTime.tryParse(r['completed_at'] as String) : null,
          firstStartedAt: (r['first_started_at'] as String?) != null ? DateTime.tryParse(r['first_started_at'] as String) : null,
        );
        final sid = (r['student_id'] as String?) ?? '';
        if (sid.isEmpty) continue;
        _byStudentId.putIfAbsent(sid, () => <HomeworkItem>[]).add(item);
      }
      _loaded = true;
      _bump();
    } catch (e) {
      // ignore
    }
  }

  Future<void> _persist(String studentId) async {
    try {
      final db = await AcademyDbService.instance.db;
      final list = _byStudentId[studentId] ?? const <HomeworkItem>[];
      // 간단히 해당 학생의 항목을 전체 리플레이스
      await db.transaction((txn) async {
        await txn.delete('homework_items', where: 'student_id = ?', whereArgs: [studentId]);
        for (final it in list) {
          await txn.insert('homework_items', {
            'id': it.id,
            'student_id': studentId,
            'title': it.title,
            'body': it.body,
            'color': it.color.value,
            'status': it.status.index,
            'accumulated_ms': it.accumulatedMs,
            'run_start': it.runStart?.toIso8601String(),
            'completed_at': it.completedAt?.toIso8601String(),
            'first_started_at': it.firstStartedAt?.toIso8601String(),
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          });
        }
      });
    } catch (e) {
      // ignore
    }
  }

  HomeworkItem add(String studentId, {required String title, required String body, Color color = const Color(0xFF1976D2)}) {
    final id = '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1 << 32)}';
    final item = HomeworkItem(id: id, title: title, body: body, color: color);
    final list = _byStudentId.putIfAbsent(studentId, () => <HomeworkItem>[]);
    list.insert(0, item);
    _bump();
    _persist(studentId);
    return item;
  }

  void edit(String studentId, HomeworkItem updated) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == updated.id);
    if (idx != -1) {
      list[idx] = updated;
      _bump();
      _persist(studentId);
    }
  }

  void remove(String studentId, String id) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    list.removeWhere((e) => e.id == id);
    _bump();
    _persist(studentId);
  }

  HomeworkItem? getById(String studentId, String id) {
    final list = _byStudentId[studentId];
    if (list == null) return null;
    final idx = list.indexWhere((e) => e.id == id);
    return idx == -1 ? null : list[idx];
  }

  HomeworkItem? runningOf(String studentId) {
    final list = _byStudentId[studentId];
    if (list == null) return null;
    final idx = list.indexWhere((e) => e.runStart != null);
    return idx == -1 ? null : list[idx];
  }

  void start(String studentId, String id) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    // pause others
    final now = DateTime.now();
    for (final e in list) {
      if (e.runStart != null) {
        e.accumulatedMs += now.difference(e.runStart!).inMilliseconds;
        e.runStart = null;
      }
    }
    final idx = list.indexWhere((e) => e.id == id);
    if (idx != -1) {
      final item = list[idx];
      final nowTime = DateTime.now();
      item.runStart = nowTime;
      item.firstStartedAt ??= nowTime;
      if (item.status == HomeworkStatus.completed) {
        item.status = HomeworkStatus.inProgress;
        item.completedAt = null;
      }
      _bump();
      _persist(studentId);
    }
  }

  void pause(String studentId, String id) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx != -1 && list[idx].runStart != null) {
      final now = DateTime.now();
      list[idx].accumulatedMs += now.difference(list[idx].runStart!).inMilliseconds;
      list[idx].runStart = null;
      _bump();
      _persist(studentId);
    }
  }

  void complete(String studentId, String id) {
    final list = _byStudentId[studentId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx != -1) {
      final item = list[idx];
      if (list[idx].runStart != null) {
        final now = DateTime.now();
        list[idx].accumulatedMs += now.difference(list[idx].runStart!).inMilliseconds;
        list[idx].runStart = null;
      }
      item.status = HomeworkStatus.completed;
      item.completedAt = DateTime.now();
      _bump();
      _persist(studentId);
    }
  }

  HomeworkItem continueAdd(String studentId, String sourceId, {required String body}) {
    final list = _byStudentId[studentId];
    if (list == null) return add(studentId, title: '과제', body: body);
    final idx = list.indexWhere((e) => e.id == sourceId);
    if (idx == -1) return add(studentId, title: '과제', body: body);
    final src = list[idx];
    final created = add(studentId, title: src.title, body: body, color: src.color);
    _persist(studentId);
    return created;
  }

  void _bump() { revision.value++; }
}
