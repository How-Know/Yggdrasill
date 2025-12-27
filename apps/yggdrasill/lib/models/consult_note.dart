import 'dart:ui';

/// 손글씨 노트의 한 점(0~1로 정규화된 좌표)
class HandwritingPoint {
  final double nx; // 0..1
  final double ny; // 0..1
  final double? pressure; // 0..1 (optional)

  const HandwritingPoint({required this.nx, required this.ny, this.pressure});

  factory HandwritingPoint.fromJson(Map<String, dynamic> j) {
    return HandwritingPoint(
      nx: (j['x'] as num).toDouble(),
      ny: (j['y'] as num).toDouble(),
      pressure: (j['p'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'x': nx,
        'y': ny,
        if (pressure != null) 'p': pressure,
      };
}

class HandwritingStroke {
  final int colorArgb;
  final double width;
  final bool isEraser;
  final List<HandwritingPoint> points;

  const HandwritingStroke({
    required this.colorArgb,
    required this.width,
    this.isEraser = false,
    required this.points,
  });

  Color get color => Color(colorArgb);

  HandwritingStroke copyWith({
    int? colorArgb,
    double? width,
    bool? isEraser,
    List<HandwritingPoint>? points,
  }) {
    return HandwritingStroke(
      colorArgb: colorArgb ?? this.colorArgb,
      width: width ?? this.width,
      isEraser: isEraser ?? this.isEraser,
      points: points ?? this.points,
    );
  }

  factory HandwritingStroke.fromJson(Map<String, dynamic> j) {
    final list = (j['points'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    return HandwritingStroke(
      colorArgb: (j['c'] as num).toInt(),
      width: (j['w'] as num).toDouble(),
      isEraser: (j['e'] as bool?) ?? false,
      points: list.map(HandwritingPoint.fromJson).toList(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'c': colorArgb,
        'w': width,
        if (isEraser) 'e': true,
        'points': points.map((p) => p.toJson()).toList(),
      };
}

class ConsultDesiredSlot {
  /// 0=월..6=일
  final int dayIndex;
  final int hour;
  final int minute;

  const ConsultDesiredSlot({required this.dayIndex, required this.hour, required this.minute});

  factory ConsultDesiredSlot.fromJson(Map<String, dynamic> j) {
    return ConsultDesiredSlot(
      dayIndex: (j['d'] as num).toInt(),
      hour: (j['h'] as num).toInt(),
      minute: (j['m'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'd': dayIndex,
        'h': hour,
        'm': minute,
      };

  String get slotKey => '$dayIndex-$hour:$minute';
}

/// 타자로 입력한 텍스트 박스(0~1 정규화 좌표/크기)
class ConsultTextBox {
  final String id;
  final double nx; // left 0..1
  final double ny; // top 0..1
  final double nw; // width 0..1
  final double nh; // height 0..1
  final String text;
  final int colorArgb;

  const ConsultTextBox({
    required this.id,
    required this.nx,
    required this.ny,
    required this.nw,
    required this.nh,
    required this.text,
    required this.colorArgb,
  });

  ConsultTextBox copyWith({
    double? nx,
    double? ny,
    double? nw,
    double? nh,
    String? text,
    int? colorArgb,
  }) {
    return ConsultTextBox(
      id: id,
      nx: nx ?? this.nx,
      ny: ny ?? this.ny,
      nw: nw ?? this.nw,
      nh: nh ?? this.nh,
      text: text ?? this.text,
      colorArgb: colorArgb ?? this.colorArgb,
    );
  }

  factory ConsultTextBox.fromJson(Map<String, dynamic> j) {
    return ConsultTextBox(
      id: (j['id'] as String?) ?? '',
      nx: (j['x'] as num?)?.toDouble() ?? 0,
      ny: (j['y'] as num?)?.toDouble() ?? 0,
      nw: (j['w'] as num?)?.toDouble() ?? 0,
      nh: (j['h'] as num?)?.toDouble() ?? 0,
      text: (j['t'] as String?) ?? '',
      colorArgb: (j['c'] as num?)?.toInt() ?? const Color(0xFFEAF2F2).toARGB32(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'x': nx,
        'y': ny,
        'w': nw,
        'h': nh,
        't': text,
        'c': colorArgb,
      };
}

class ConsultNote {
  final int version;
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  /// 문의(희망) 수업 시간
  final int? desiredWeekday; // 1=Mon .. 7=Sun (DateTime.weekday)
  final int? desiredHour; // 0..23
  final int? desiredMinute; // 0..59
  /// 다중 선택 희망시간(0=월..6=일). 비어있으면 `desiredWeekday/hour/minute`(레거시)를 사용.
  final List<ConsultDesiredSlot> desiredSlots;
  /// "해당 주차 이후에 모두 반영"을 위한 시작 주(월요일, date-only)
  final DateTime? desiredStartWeek;
  final List<HandwritingStroke> strokes;
  /// 텍스트 박스(타자 입력)
  final List<ConsultTextBox> textBoxes;

  const ConsultNote({
    this.version = 1,
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.desiredWeekday,
    this.desiredHour,
    this.desiredMinute,
    this.desiredSlots = const <ConsultDesiredSlot>[],
    this.desiredStartWeek,
    required this.strokes,
    this.textBoxes = const <ConsultTextBox>[],
  });

  ConsultNote copyWith({
    String? title,
    DateTime? updatedAt,
    int? desiredWeekday,
    int? desiredHour,
    int? desiredMinute,
    List<ConsultDesiredSlot>? desiredSlots,
    DateTime? desiredStartWeek,
    List<HandwritingStroke>? strokes,
    List<ConsultTextBox>? textBoxes,
  }) {
    return ConsultNote(
      version: version,
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      desiredWeekday: desiredWeekday ?? this.desiredWeekday,
      desiredHour: desiredHour ?? this.desiredHour,
      desiredMinute: desiredMinute ?? this.desiredMinute,
      desiredSlots: desiredSlots ?? this.desiredSlots,
      desiredStartWeek: desiredStartWeek ?? this.desiredStartWeek,
      strokes: strokes ?? this.strokes,
      textBoxes: textBoxes ?? this.textBoxes,
    );
  }

  factory ConsultNote.fromJson(Map<String, dynamic> j) {
    final createdStr = (j['createdAt'] as String?) ?? '';
    final updatedStr = (j['updatedAt'] as String?) ?? '';
    final strokesList = (j['strokes'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();

    List<ConsultDesiredSlot> desiredSlots = const <ConsultDesiredSlot>[];
    try {
      final raw = (j['ds'] as List<dynamic>?)?.cast<Map<String, dynamic>>();
      if (raw != null) {
        desiredSlots = raw.map(ConsultDesiredSlot.fromJson).toList();
      }
    } catch (_) {}

    // 레거시(단일) 값만 있는 경우 → desiredSlots로 승격
    if (desiredSlots.isEmpty) {
      final dw = (j['dw'] as num?)?.toInt();
      final dh = (j['dh'] as num?)?.toInt();
      final dm = (j['dm'] as num?)?.toInt();
      if (dw != null && dh != null && dm != null) {
        final dayIdx = (dw - 1).clamp(0, 6);
        desiredSlots = <ConsultDesiredSlot>[ConsultDesiredSlot(dayIndex: dayIdx, hour: dh, minute: dm)];
      }
    }

    DateTime? desiredStartWeek;
    final dsw = (j['dsw'] as String?) ?? '';
    if (dsw.isNotEmpty) {
      desiredStartWeek = DateTime.tryParse(dsw);
      if (desiredStartWeek != null) {
        desiredStartWeek = DateTime(desiredStartWeek.year, desiredStartWeek.month, desiredStartWeek.day);
      }
    }

    List<ConsultTextBox> textBoxes = const <ConsultTextBox>[];
    try {
      final raw = (j['tb'] as List<dynamic>?)?.cast<Map<String, dynamic>>();
      if (raw != null) {
        textBoxes = raw.map(ConsultTextBox.fromJson).toList();
      }
    } catch (_) {}
    return ConsultNote(
      version: (j['version'] as num?)?.toInt() ?? 1,
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '상담 노트',
      createdAt: createdStr.isNotEmpty ? DateTime.parse(createdStr) : DateTime.now(),
      updatedAt: updatedStr.isNotEmpty ? DateTime.parse(updatedStr) : DateTime.now(),
      desiredWeekday: (j['dw'] as num?)?.toInt(),
      desiredHour: (j['dh'] as num?)?.toInt(),
      desiredMinute: (j['dm'] as num?)?.toInt(),
      desiredSlots: desiredSlots,
      desiredStartWeek: desiredStartWeek,
      strokes: strokesList.map(HandwritingStroke.fromJson).toList(),
      textBoxes: textBoxes,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (desiredWeekday != null) 'dw': desiredWeekday,
        if (desiredHour != null) 'dh': desiredHour,
        if (desiredMinute != null) 'dm': desiredMinute,
        if (desiredSlots.isNotEmpty) 'ds': desiredSlots.map((s) => s.toJson()).toList(),
        if (desiredStartWeek != null) 'dsw': DateTime(desiredStartWeek!.year, desiredStartWeek!.month, desiredStartWeek!.day).toIso8601String(),
        'strokes': strokes.map((s) => s.toJson()).toList(),
        if (textBoxes.isNotEmpty) 'tb': textBoxes.map((b) => b.toJson()).toList(),
      };
}

class ConsultNoteMeta {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int? desiredWeekday;
  final int? desiredHour;
  final int? desiredMinute;
  final int strokeCount;

  const ConsultNoteMeta({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.desiredWeekday,
    this.desiredHour,
    this.desiredMinute,
    required this.strokeCount,
  });

  factory ConsultNoteMeta.fromJson(Map<String, dynamic> j) {
    final createdStr = (j['createdAt'] as String?) ?? '';
    final updatedStr = (j['updatedAt'] as String?) ?? '';
    return ConsultNoteMeta(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '상담 노트',
      createdAt: createdStr.isNotEmpty ? DateTime.parse(createdStr) : DateTime.now(),
      updatedAt: updatedStr.isNotEmpty ? DateTime.parse(updatedStr) : DateTime.now(),
      desiredWeekday: (j['dw'] as num?)?.toInt(),
      desiredHour: (j['dh'] as num?)?.toInt(),
      desiredMinute: (j['dm'] as num?)?.toInt(),
      strokeCount: (j['strokeCount'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (desiredWeekday != null) 'dw': desiredWeekday,
        if (desiredHour != null) 'dh': desiredHour,
        if (desiredMinute != null) 'dm': desiredMinute,
        'strokeCount': strokeCount,
      };
}


