class StudentPaymentInfo {
  final String? id;
  final String studentId;
  final DateTime registrationDate;
  final String paymentMethod;
  final int tuitionFee;
  final int latenessThreshold; // 지각 기준 (분 단위)
  final bool scheduleNotification; // 수강일자 안내
  final bool attendanceNotification; // 출결
  final bool departureNotification; // 하원
  final bool latenessNotification; // 지각
  final DateTime createdAt;
  final DateTime updatedAt;

  StudentPaymentInfo({
    this.id,
    required this.studentId,
    required this.registrationDate,
    required this.paymentMethod,
    required this.tuitionFee,
    this.latenessThreshold = 10, // 기본 10분
    this.scheduleNotification = false,
    this.attendanceNotification = false,
    this.departureNotification = false,
    this.latenessNotification = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory StudentPaymentInfo.fromJson(Map<String, dynamic> json) {
    return StudentPaymentInfo(
      id: json['id'] as String?,
      studentId: json['student_id'] as String,
      registrationDate: DateTime.parse(json['registration_date'] as String),
      paymentMethod: json['payment_method'] as String,
      tuitionFee: json['tuition_fee'] as int,
      latenessThreshold: json['lateness_threshold'] as int? ?? 10,
      scheduleNotification: (json['schedule_notification'] as int? ?? 0) == 1,
      attendanceNotification: (json['attendance_notification'] as int? ?? 0) == 1,
      departureNotification: (json['departure_notification'] as int? ?? 0) == 1,
      latenessNotification: (json['lateness_notification'] as int? ?? 0) == 1,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'student_id': studentId,
      'registration_date': registrationDate.toIso8601String(),
      'payment_method': paymentMethod,
      'tuition_fee': tuitionFee,
      'lateness_threshold': latenessThreshold,
      'schedule_notification': scheduleNotification ? 1 : 0,
      'attendance_notification': attendanceNotification ? 1 : 0,
      'departure_notification': departureNotification ? 1 : 0,
      'lateness_notification': latenessNotification ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  StudentPaymentInfo copyWith({
    String? id,
    String? studentId,
    DateTime? registrationDate,
    String? paymentMethod,
    int? tuitionFee,
    int? latenessThreshold,
    bool? scheduleNotification,
    bool? attendanceNotification,
    bool? departureNotification,
    bool? latenessNotification,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return StudentPaymentInfo(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      registrationDate: registrationDate ?? this.registrationDate,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      tuitionFee: tuitionFee ?? this.tuitionFee,
      latenessThreshold: latenessThreshold ?? this.latenessThreshold,
      scheduleNotification: scheduleNotification ?? this.scheduleNotification,
      attendanceNotification: attendanceNotification ?? this.attendanceNotification,
      departureNotification: departureNotification ?? this.departureNotification,
      latenessNotification: latenessNotification ?? this.latenessNotification,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

enum PaymentMethod {
  monthly('월납'),
  quarterly('분기납'),
  semiannual('반기납'),
  annual('연납');

  const PaymentMethod(this.displayName);
  final String displayName;
}