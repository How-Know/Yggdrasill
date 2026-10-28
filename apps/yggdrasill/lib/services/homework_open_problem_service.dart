import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 과제 문항 중 정답 기록이 없는 문항 수. 숙제 배정 트리거와 같은 기준이다.
class HomeworkOpenProblemCount {
  const HomeworkOpenProblemCount({required this.total, required this.open});

  final int total;
  final int open;
}

class HomeworkOpenProblemService {
  HomeworkOpenProblemService._();

  static final HomeworkOpenProblemService instance =
      HomeworkOpenProblemService._();

  /// 문항 스냅샷이 없는 과제는 결과에 없다. 실패하면 빈 맵.
  Future<Map<String, HomeworkOpenProblemCount>> fetch(
    Iterable<String> itemIds,
  ) async {
    final ids = itemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return const <String, HomeworkOpenProblemCount>{};
    try {
      final res = await Supabase.instance.client.rpc(
        'staff_homework_open_problem_counts_v1',
        params: <String, dynamic>{'p_item_ids': ids},
      );
      final out = <String, HomeworkOpenProblemCount>{};
      if (res is List) {
        for (final row in res.whereType<Map>()) {
          final id = '${row['homework_item_id'] ?? ''}'.trim();
          final total = (row['total_count'] as num?)?.toInt() ?? 0;
          final open = (row['open_count'] as num?)?.toInt() ?? 0;
          if (id.isEmpty || total <= 0) continue;
          out[id] = HomeworkOpenProblemCount(total: total, open: open);
        }
      }
      return out;
    } catch (e, st) {
      debugPrint('[HOMEWORK_OPEN_PROBLEMS][fetch][ERROR] $e\n$st');
      return const <String, HomeworkOpenProblemCount>{};
    }
  }
}
