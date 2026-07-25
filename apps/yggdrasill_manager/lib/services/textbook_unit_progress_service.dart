import 'textbook_book_registry.dart';
import 'textbook_pdf_service.dart';

class TextbookUnitProgress {
  const TextbookUnitProgress({
    required this.completed,
    required this.total,
  });

  const TextbookUnitProgress.empty()
      : completed = 0,
        total = 0;

  final int completed;
  final int total;
}

/// 마이그레이션 탭과 같은 규칙으로 실제 소단원 3단계 진행률을 계산한다.
class TextbookUnitProgressService {
  TextbookUnitProgressService({
    TextbookBookRegistry? registry,
    TextbookPdfService? pdfService,
  })  : _registry = registry ?? TextbookBookRegistry(),
        _pdfService = pdfService ?? TextbookPdfService();

  final TextbookBookRegistry _registry;
  final TextbookPdfService _pdfService;

  Future<TextbookUnitProgress> load({
    required String academyId,
    required String bookId,
    required String gradeLabel,
  }) async {
    final row = await _registry.loadPayload(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
    );
    final payload = (row?['payload'] as Map?)?.cast<String, dynamic>();
    final scopes = stageScopesFromPayload(payload);
    if (scopes.isEmpty) return const TextbookUnitProgress.empty();
    final statuses = await _pdfService.fetchStageStatuses(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      scopes: scopes,
    );
    return TextbookUnitProgress(
      completed: statuses.where((status) => status.completedStages >= 3).length,
      total: scopes.length,
    );
  }

  static List<Map<String, dynamic>> stageScopesFromPayload(
    Map<String, dynamic>? payload,
  ) {
    if (payload == null) return const <Map<String, dynamic>>[];
    final units = payload['units'];
    if (units is! List) return const <Map<String, dynamic>>[];
    final isWonri =
        '${payload['series'] ?? ''}'.trim().toLowerCase() == 'wonri';
    final out = <Map<String, dynamic>>[];
    for (var b = 0; b < units.length; b += 1) {
      final rawBig = units[b];
      if (rawBig is! Map) continue;
      final big = Map<String, dynamic>.from(rawBig);
      final bigOrder = _asInt(big['order_index']) ?? b;
      final middles = big['middles'];
      if (middles is! List) continue;
      for (var m = 0; m < middles.length; m += 1) {
        final rawMid = middles[m];
        if (rawMid is! Map) continue;
        final mid = Map<String, dynamic>.from(rawMid);
        final midOrder = _asInt(mid['order_index']) ?? m;
        if (isWonri) {
          final subUnits = mid['sub_units'];
          if (subUnits is! List || subUnits.isEmpty) continue;
          for (var s = 0; s < subUnits.length; s += 1) {
            final rawSubUnit = subUnits[s];
            if (rawSubUnit is! Map) continue;
            final subUnit = Map<String, dynamic>.from(rawSubUnit);
            final startPage = _asInt(subUnit['start_page']);
            final endPage = _asInt(subUnit['end_page']);
            if (startPage == null ||
                endPage == null ||
                startPage <= 0 ||
                endPage < startPage) {
              continue;
            }
            out.add(<String, dynamic>{
              'big_order': bigOrder,
              'mid_order': midOrder,
              'sub_key': 'W$s',
              'scope_kind': 'wonri_sub_unit',
              'unit_row_index': _asInt(subUnit['order_index']) ?? s,
              'body_start_page': startPage,
              'body_end_page': endPage,
            });
          }
          continue;
        }
        final smalls = mid['smalls'];
        if (smalls is! List || smalls.isEmpty) continue;
        for (final rawSmall in smalls) {
          if (rawSmall is! Map) continue;
          final subKey = '${rawSmall['sub_key'] ?? ''}'.trim().toUpperCase();
          if (subKey.isEmpty) continue;
          out.add(<String, dynamic>{
            'big_order': bigOrder,
            'mid_order': midOrder,
            'sub_key': subKey,
          });
        }
      }
    }
    return out;
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }
}
