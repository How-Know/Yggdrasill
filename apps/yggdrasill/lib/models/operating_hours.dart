class OperatingHours {
  final int? id;
  final int dayOfWeek;
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final List<BreakTime> breakTimes;

  OperatingHours({
    this.id,
    required this.dayOfWeek,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    this.breakTimes = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'dayOfWeek': dayOfWeek,
      'startHour': startHour,
      'startMinute': startMinute,
      'endHour': endHour,
      'endMinute': endMinute,
      'breakTimes': breakTimes.map((breakTime) => breakTime.toJson()).toList(),
    };
  }

  factory OperatingHours.fromJson(Map<String, dynamic> json) {
    return OperatingHours(
      id: json['id'] as int?,
      dayOfWeek: json['dayOfWeek'] as int,
      startHour: json['startHour'] as int,
      startMinute: json['startMinute'] as int,
      endHour: json['endHour'] as int,
      endMinute: json['endMinute'] as int,
      breakTimes: (json['breakTimes'] as List)
          .map((breakTime) => BreakTime.fromJson(breakTime))
          .toList(),
    );
  }
}

class BreakTime {
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;

  BreakTime({
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
  });

  Map<String, dynamic> toJson() {
    return {
      'startHour': startHour,
      'startMinute': startMinute,
      'endHour': endHour,
      'endMinute': endMinute,
    };
  }

  factory BreakTime.fromJson(Map<String, dynamic> json) {
    return BreakTime(
      startHour: json['startHour'] as int,
      startMinute: json['startMinute'] as int,
      endHour: json['endHour'] as int,
      endMinute: json['endMinute'] as int,
    );
  }
} 