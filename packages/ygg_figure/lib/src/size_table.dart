/// 그림 크기 표: 양식 × 자리마다 그림 크기를 하나로 정해 둔다.
///
/// 그림은 실리는 양식(과제·내신·모의고사)과 자리(본문 아래·선지 아래·본문 오른쪽)에 따라
/// 이 표의 크기로 다시 그려진다. 다시 그릴 때 도형만 커지거나 작아지고 글자와 선 굵기는 그대로다.
/// 표로 안 되는 그림만 그림 파일의 "size" 에 따로 적는다(희귀 케이스).
///
/// 크기는 본문 글자 크기 기준(em)이다. 본문 글자가 달라져도 그림 속 글자와 본문의 비율이 같게 남는다.
///
/// 칸의 너비는 글자 수("width_em")로 적거나, 그 양식의 본문 너비에 대한 비율("width_ratio")로 적는다.
/// 비율로 적으려면 표의 "columns" 에 그 양식의 본문 너비(글자 수)가 있어야 한다.
/// 글자 수는 인쇄본의 본문 글자 크기로 센다(그림은 인쇄될 때 그림 속 글자가 본문 글자와 같아지게
/// 놓이기 때문이다). 과제형(A4·2단)은 본문이 10pt 이고 한 단이 250.5pt 라 25.05 글자,
/// 내신형(경신중 틀·B4·2단)은 10.5pt·297.6pt 라 28.34 글자, 모의고사형(8절·2단)은 11pt·324.8pt 라 29.53 글자다.
///
/// 한 양식·한 자리 안에서 그림은 크기 부류(소·중·대)로 나뉜다. 부류는 그림 파일의
/// "size": {"variant": "small" | "medium" | "large"} 에 적고, 표에는 부류마다 칸을 둔다.
/// 표에 그 부류의 칸이 없으면 부류 이름이 없는 기본 칸을 쓴다(그래서 기본 칸이 곧 "중"이다).
library;

/// 표에 쓰는 양식 이름.
const figureFormats = ['assignment', 'naesin', 'mock'];

/// 표에 쓰는 자리 이름(v2 인쇄 렌더러의 그림 자리 이름과 같다).
const figurePositions = ['below-stem', 'below-choices', 'inline-right'];

/// 그림의 크기 부류(소·중·대). 그림 파일의 "size"."variant" 에 적는 이름이다.
const figureSizeClasses = ['small', 'medium', 'large'];

/// TeX 1pt 의 길이(mm).
const mmPerPt = 25.4 / 72.27;

/// 그림 한 장이 들어갈 칸의 크기.
class FigureSlot {
  const FigureSlot({
    required this.format,
    required this.position,
    required this.widthEm,
    this.widthRatio,
    this.maxHeightEm,
    this.variant,
    this.note,
    this.fromFigure = false,
  });

  final String format;
  final String position;

  /// 같은 양식·같은 자리 안에서 칸을 더 나눌 때의 이름(예: "wide"). 없으면 기본 칸.
  final String? variant;

  /// 그림의 너비.
  final double widthEm;

  /// 본문 너비에 대한 비율로 정한 칸이면 그 비율(0~1). 이때 [widthEm] 은 비율 × 본문 너비다.
  final double? widthRatio;

  /// 이 높이를 넘으면 너비 대신 높이에 맞춘다. 없으면 높이는 따지지 않는다.
  final double? maxHeightEm;

  /// 따로 정한 이유(희귀 케이스 표시).
  final String? note;

  /// 표가 아니라 그림 파일에 따로 적힌 값이면 true.
  final bool fromFigure;

  String get key => '$format/$position';

  Map<String, dynamic> toJson() => {
        'format': format,
        'position': position,
        if (variant != null) 'variant': variant,
        if (widthRatio != null) 'width_ratio': widthRatio else 'width_em': widthEm,
        if (maxHeightEm != null) 'max_height_em': maxHeightEm,
        if (note != null) 'note': note,
      };
}

class FigureSizeTable {
  FigureSizeTable(this.slots, {Map<String, double>? columns}) : columns = columns ?? {};

  /// 표 파일({"format": "ygg-figure-sizes/1", "columns": {...}, "slots": [...]})을 읽는다.
  factory FigureSizeTable.fromJson(Map<String, dynamic> json) {
    if (json['format'] != sizeTableFormat) {
      throw FormatException('그림 크기 표가 아닙니다(format 이 $sizeTableFormat 이어야 합니다)');
    }
    final columns = <String, double>{
      for (final e in (json['columns'] as Map? ?? const {}).entries) e.key as String: (e.value as num).toDouble(),
    };
    final slots = <FigureSlot>[];
    for (final raw in (json['slots'] as List? ?? const [])) {
      final m = (raw as Map).cast<String, dynamic>();
      final format = m['format'] as String;
      final ratio = (m['width_ratio'] as num?)?.toDouble();
      final column = columns[format];
      if (ratio != null && column == null) throw FormatException('본문 너비(columns.$format)가 없는데 비율로 적은 칸이 있습니다: $m');
      final width = ratio != null ? ratio * column! : (m['width_em'] as num?)?.toDouble();
      if (width == null || !(width > 0)) throw FormatException('너비(width_em 또는 width_ratio)가 없는 칸이 있습니다: $m');
      slots.add(FigureSlot(
        format: format,
        position: m['position'] as String,
        variant: m['variant'] as String?,
        widthEm: width,
        widthRatio: ratio,
        maxHeightEm: (m['max_height_em'] as num?)?.toDouble(),
        note: m['note'] as String?,
      ));
    }
    return FigureSizeTable(slots, columns: columns);
  }

  static const sizeTableFormat = 'ygg-figure-sizes/1';

  final List<FigureSlot> slots;

  /// 양식마다의 본문 너비(글자 수). 비율로 정한 칸의 기준이다.
  final Map<String, double> columns;

  Map<String, dynamic> toJson() => {
        'format': sizeTableFormat,
        if (columns.isNotEmpty) 'columns': columns,
        'slots': [for (final s in slots) s.toJson()],
      };

  /// 표에서 칸을 찾는다. [variant] 칸이 없으면 기본 칸을 준다. 그것도 없으면 null(제 크기로 싣는다).
  FigureSlot? slot(String format, String position, {String? variant}) {
    FigureSlot? base;
    for (final s in slots) {
      if (s.format != format || s.position != position) continue;
      if (variant != null && s.variant == variant) return s;
      if (s.variant == null) base = s;
    }
    return base;
  }

  /// 그림 한 장이 [format] × [position] 에 실릴 때의 칸.
  ///
  /// 그림 파일의 "size" 가 먼저다:
  ///   "size": {"variant": "wide"}                       → 표의 나눈 칸을 쓴다.
  ///   "size": {"overrides": {"mock/below-stem": {"width_em": 26, "note": "평면이 넓다"}}}
  ///                                                     → 이 그림만 따로 정한 값(희귀 케이스).
  FigureSlot? slotFor(Map<String, dynamic> figure, String format, String position) {
    final size = figure['size'];
    String? variant;
    if (size is Map) {
      variant = size['variant'] as String?;
      final own = (size['overrides'] as Map?)?['$format/$position'];
      if (own is Map) {
        final width = (own['width_em'] as num?)?.toDouble();
        if (width != null && width > 0) {
          final base = slot(format, position, variant: variant);
          return FigureSlot(
            format: format,
            position: position,
            widthEm: width,
            maxHeightEm: (own['max_height_em'] as num?)?.toDouble() ?? base?.maxHeightEm,
            note: own['note'] as String?,
            fromFigure: true,
          );
        }
      }
    }
    return slot(format, position, variant: variant);
  }
}
