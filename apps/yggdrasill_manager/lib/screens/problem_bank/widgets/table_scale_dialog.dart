import 'package:flutter/material.dart';

/// 문항에 포함된 표의 가로·세로 배율을 독립적으로 조절하는 다이얼로그.
///
/// 표는 두 종류가 있다:
///   * `struct` — 구조화된 표 ([표행]/[표셀]). 셀 폭/높이만 스케일 → 폰트 크기 본문 그대로.
///   * `raw`    — VLM 이 직접 쓴 tabular ([표시작]/[표끝]). `\scalebox` 기하 스케일 →
///                 폰트 크기도 같이 스케일되는 한계. 사용자에게 라벨로 안내.
///
/// 결과는 `TableScaleResult` 로 반환. 취소 시 `null`.
class TableScaleDialog extends StatefulWidget {
  const TableScaleDialog({
    super.key,
    required this.tables,
    this.initialScales = const <String, TableScaleValue>{},
    this.initialDefault = const TableScaleValue(),
  });

  final List<TableScaleEntry> tables;
  final Map<String, TableScaleValue> initialScales;
  final TableScaleValue initialDefault;

  static Future<TableScaleResult?> show(
    BuildContext context, {
    required List<TableScaleEntry> tables,
    Map<String, TableScaleValue> initialScales = const {},
    TableScaleValue initialDefault = const TableScaleValue(),
  }) {
    return showDialog<TableScaleResult>(
      context: context,
      barrierDismissible: true,
      builder: (_) => TableScaleDialog(
        tables: tables,
        initialScales: initialScales,
        initialDefault: initialDefault,
      ),
    );
  }

  @override
  State<TableScaleDialog> createState() => _TableScaleDialogState();
}

class _TableScaleDialogState extends State<TableScaleDialog> {
  static const double _min = 0.6;
  static const double _max = 1.4;
  static const int _divisions = 16;

  late Map<String, TableScaleValue> _scales;
  late TableScaleValue _defaultScale;

  @override
  void initState() {
    super.initState();
    _scales = <String, TableScaleValue>{
      for (final t in widget.tables)
        t.key: widget.initialScales[t.key] ?? widget.initialDefault,
    };
    _defaultScale = widget.initialDefault;
  }

  void _resetAll() {
    setState(() {
      for (final t in widget.tables) {
        _scales[t.key] = const TableScaleValue();
      }
      _defaultScale = const TableScaleValue();
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasTables = widget.tables.isNotEmpty;
    return AlertDialog(
      backgroundColor: const Color(0xFF18181B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
      contentPadding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      title: Row(
        children: [
          const Icon(Icons.table_chart_outlined,
              color: Color(0xFF60A5FA), size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '표 크기 조절',
              style: TextStyle(
                color: Color(0xFFE5E7EB),
                fontSize: 14.4,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          TextButton(
            onPressed: _resetAll,
            child: const Text(
              '모두 100%',
              style: TextStyle(
                fontSize: 11.4,
                color: Color(0xFF9CA3AF),
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 440),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!hasTables)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      '이 문항에는 조절 가능한 표가 없습니다.',
                      style: TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontSize: 12,
                      ),
                    ),
                  ),
                for (final t in widget.tables) _buildTableRow(t),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            '취소',
            style: TextStyle(color: Color(0xFF9CA3AF)),
          ),
        ),
        FilledButton(
          onPressed: !hasTables
              ? null
              : () => Navigator.of(context).pop(
                    TableScaleResult(
                      scales: Map.of(_scales),
                      defaultScale: _defaultScale,
                    ),
                  ),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF60A5FA),
            foregroundColor: Colors.white,
          ),
          child: const Text('저장'),
        ),
      ],
    );
  }

  Widget _buildTableRow(TableScaleEntry entry) {
    final scale = _scales[entry.key] ?? const TableScaleValue();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F23),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3F3F46)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                entry.label,
                style: const TextStyle(
                  color: Color(0xFFE5E7EB),
                  fontSize: 12.6,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: (entry.type == 'raw'
                          ? Colors.orangeAccent
                          : const Color(0xFF60A5FA))
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  entry.type == 'raw' ? 'raw tabular' : '구조화 표',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: entry.type == 'raw'
                        ? Colors.orangeAccent
                        : const Color(0xFF60A5FA),
                  ),
                ),
              ),
            ],
          ),
          if (entry.type == 'raw')
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '* raw tabular 는 폭/높이 스케일 시 폰트 크기도 같이 변합니다.',
                style: TextStyle(
                  color: Color(0xFF9CA3AF),
                  fontSize: 10.6,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          const SizedBox(height: 6),
          _buildSlider(
            title: '가로',
            value: scale.widthScale,
            onChanged: (v) {
              setState(() {
                _scales[entry.key] = scale.copyWith(widthScale: v);
              });
            },
          ),
          _buildSlider(
            title: '세로',
            value: scale.heightScale,
            onChanged: (v) {
              setState(() {
                _scales[entry.key] = scale.copyWith(heightScale: v);
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSlider({
    required String title,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    final clamped = value.clamp(_min, _max);
    final pct = (clamped * 100).round();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFFE5E7EB),
                fontSize: 11.8,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: clamped,
                min: _min,
                max: _max,
                divisions: _divisions,
                activeColor: const Color(0xFF60A5FA),
                inactiveColor: const Color(0xFF3F3F46),
                onChanged: (v) {
                  final rounded = (v * 20).roundToDouble() / 20;
                  onChanged(rounded);
                },
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$pct%',
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: Color(0xFFE5E7EB),
                fontSize: 11.6,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TableScaleEntry {
  const TableScaleEntry({
    required this.key,
    required this.label,
    required this.type,
    this.maxCols = 0,
  });

  /// 메타 저장 키. 예) `struct:1`, `raw:2`.
  final String key;

  /// UI 에 보일 사용자 라벨. 예) `표 1`.
  final String label;

  /// 'struct' 또는 'raw'.
  final String type;

  /// struct 표의 최대 컬럼 수. raw 표나 파싱 실패 시 0.
  /// 컬럼별 독립 너비 UI 의 슬라이더 개수 결정에 사용.
  final int maxCols;
}

class TableScaleValue {
  const TableScaleValue({
    this.widthScale = 1.0,
    this.heightScale = 1.0,
    this.columnScales,
  });

  final double widthScale;
  final double heightScale;

  /// struct 표의 컬럼별 상대 가중치(0.3 ~ 2.5). null 이면 전부 균등(기본).
  /// 합이 1 일 필요는 없고, 렌더러가 합으로 정규화해 컬럼 폭 비율로 쓴다.
  /// 예) [1, 2, 1] → 가운데 컬럼이 양쪽의 2 배 폭.
  final List<double>? columnScales;

  TableScaleValue copyWith({
    double? widthScale,
    double? heightScale,
    List<double>? columnScales,
    bool clearColumnScales = false,
  }) =>
      TableScaleValue(
        widthScale: widthScale ?? this.widthScale,
        heightScale: heightScale ?? this.heightScale,
        columnScales:
            clearColumnScales ? null : (columnScales ?? this.columnScales),
      );

  Map<String, dynamic> toJson() => {
        'widthScale': widthScale,
        'heightScale': heightScale,
        if (columnScales != null && columnScales!.isNotEmpty)
          'columnScales': columnScales,
      };

  static TableScaleValue fromJson(dynamic raw) {
    if (raw is! Map) return const TableScaleValue();
    final w = raw['widthScale'] ?? raw['w'] ?? 1.0;
    final h = raw['heightScale'] ?? raw['h'] ?? 1.0;
    final cs = raw['columnScales'];
    List<double>? parsedCs;
    if (cs is List && cs.isNotEmpty) {
      parsedCs = <double>[
        for (final v in cs)
          if (v is num) v.toDouble() else 1.0,
      ];
    }
    return TableScaleValue(
      widthScale: (w is num) ? w.toDouble() : 1.0,
      heightScale: (h is num) ? h.toDouble() : 1.0,
      columnScales: parsedCs,
    );
  }

  bool get isDefault =>
      (widthScale - 1.0).abs() < 1e-3 &&
      (heightScale - 1.0).abs() < 1e-3 &&
      (columnScales == null ||
          columnScales!.every((e) => (e - 1.0).abs() < 1e-3));
}

class TableScaleResult {
  const TableScaleResult({
    required this.scales,
    required this.defaultScale,
  });

  final Map<String, TableScaleValue> scales;
  final TableScaleValue defaultScale;
}
