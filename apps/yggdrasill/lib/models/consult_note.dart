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

class ConsultNote {
  final int version;
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<HandwritingStroke> strokes;

  const ConsultNote({
    this.version = 1,
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.strokes,
  });

  ConsultNote copyWith({
    String? title,
    DateTime? updatedAt,
    List<HandwritingStroke>? strokes,
  }) {
    return ConsultNote(
      version: version,
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      strokes: strokes ?? this.strokes,
    );
  }

  factory ConsultNote.fromJson(Map<String, dynamic> j) {
    final createdStr = (j['createdAt'] as String?) ?? '';
    final updatedStr = (j['updatedAt'] as String?) ?? '';
    final strokesList = (j['strokes'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    return ConsultNote(
      version: (j['version'] as num?)?.toInt() ?? 1,
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '상담 노트',
      createdAt: createdStr.isNotEmpty ? DateTime.parse(createdStr) : DateTime.now(),
      updatedAt: updatedStr.isNotEmpty ? DateTime.parse(updatedStr) : DateTime.now(),
      strokes: strokesList.map(HandwritingStroke.fromJson).toList(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'strokes': strokes.map((s) => s.toJson()).toList(),
      };
}

class ConsultNoteMeta {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int strokeCount;

  const ConsultNoteMeta({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
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
      strokeCount: (j['strokeCount'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'strokeCount': strokeCount,
      };
}


