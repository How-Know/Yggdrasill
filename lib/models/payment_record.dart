class PaymentRecord {
  final int? id;
  final String studentId; // student.id는 String 타입이므로 맞춤
  final int cycle;
  final DateTime dueDate; // 수업료를 내야하는 날짜
  final DateTime? paidDate; // 실제로 납부한 날짜

  PaymentRecord({
    this.id,
    required this.studentId,
    required this.cycle,
    required this.dueDate,
    this.paidDate,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'student_id': studentId,
      'cycle': cycle,
      'due_date': dueDate.millisecondsSinceEpoch,
      'paid_date': paidDate?.millisecondsSinceEpoch,
    };
  }

  factory PaymentRecord.fromMap(Map<String, dynamic> map) {
    return PaymentRecord(
      id: map['id']?.toInt(),
      studentId: map['student_id']?.toString() ?? '', // String으로 변경
      cycle: map['cycle']?.toInt() ?? 0,
      dueDate: DateTime.fromMillisecondsSinceEpoch(map['due_date'] ?? 0),
      paidDate: map['paid_date'] != null 
        ? DateTime.fromMillisecondsSinceEpoch(map['paid_date'])
        : null,
    );
  }

  PaymentRecord copyWith({
    int? id,
    String? studentId,
    int? cycle,
    DateTime? dueDate,
    DateTime? paidDate,
  }) {
    return PaymentRecord(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      cycle: cycle ?? this.cycle,
      dueDate: dueDate ?? this.dueDate,
      paidDate: paidDate ?? this.paidDate,
    );
  }
}