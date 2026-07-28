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
  /// 납부 채널: cash / transfer / card / app
  final String paymentChannel;
  /// 결제 시 특이사항 메모 (nullable)
  final String? paymentNote;
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
    this.paymentChannel = PaymentChannel.card,
    this.paymentNote,
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
      paymentChannel: PaymentChannel.normalize(json['payment_channel'] as String?),
      paymentNote: json['payment_note'] as String?,
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
      'payment_channel': PaymentChannel.normalize(paymentChannel),
      'payment_note': paymentNote,
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
    String? paymentChannel,
    String? paymentNote,
    bool clearPaymentNote = false,
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
      attendanceNotification:
          attendanceNotification ?? this.attendanceNotification,
      departureNotification:
          departureNotification ?? this.departureNotification,
      latenessNotification: latenessNotification ?? this.latenessNotification,
      paymentChannel: paymentChannel ?? this.paymentChannel,
      paymentNote: clearPaymentNote ? null : (paymentNote ?? this.paymentNote),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 납부 주기(월납 등) — DB 컬럼 `payment_method`
enum PaymentMethod {
  monthly('월납'),
  quarterly('분기납'),
  semiannual('반기납'),
  annual('연납');

  const PaymentMethod(this.displayName);
  final String displayName;
}

/// 납부 채널(현금/이체/카드/앱) — DB 컬럼 `payment_channel`
class PaymentChannel {
  static const String cash = 'cash';
  static const String transfer = 'transfer';
  static const String card = 'card';
  static const String app = 'app';

  static const List<String> values = [cash, transfer, card, app];

  static String normalize(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    if (values.contains(v)) return v;
    return card;
  }

  static String displayName(String? raw) {
    switch (normalize(raw)) {
      case cash:
        return '현금';
      case transfer:
        return '이체';
      case app:
        return '앱';
      case card:
      default:
        return '카드';
    }
  }
}
