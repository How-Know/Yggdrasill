class OperatingHours {
  final DateTime startTime;
  final DateTime endTime;
  final List<BreakTime> breakTimes;

  OperatingHours({
    required this.startTime,
    required this.endTime,
    this.breakTimes = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'startTime': startTime.toIso8601String(),
      'endTime': endTime.toIso8601String(),
      'breakTimes': breakTimes.map((breakTime) => breakTime.toJson()).toList(),
    };
  }

  factory OperatingHours.fromJson(Map<String, dynamic> json) {
    return OperatingHours(
      startTime: DateTime.parse(json['startTime']),
      endTime: DateTime.parse(json['endTime']),
      breakTimes: (json['breakTimes'] as List)
          .map((breakTime) => BreakTime.fromJson(breakTime))
          .toList(),
    );
  }
}

class BreakTime {
  final DateTime startTime;
  final DateTime endTime;

  BreakTime({
    required this.startTime,
    required this.endTime,
  });

  Map<String, dynamic> toJson() {
    return {
      'startTime': startTime.toIso8601String(),
      'endTime': endTime.toIso8601String(),
    };
  }

  factory BreakTime.fromJson(Map<String, dynamic> json) {
    return BreakTime(
      startTime: DateTime.parse(json['startTime']),
      endTime: DateTime.parse(json['endTime']),
    );
  }
} 