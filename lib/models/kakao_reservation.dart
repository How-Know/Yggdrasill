import 'package:intl/intl.dart';

class KakaoReservation {
  final String id;
  final DateTime createdAt;
  final String? name;
  final String? studentName;
  final String? phone;
  final String message;
  final DateTime? desiredDateTime;
  final bool isRead;
  final String? kakaoUserId;
  final String? kakaoNickname;

  KakaoReservation({
    required this.id,
    required this.createdAt,
    required this.message,
    this.name,
    this.studentName,
    this.phone,
    this.desiredDateTime,
    this.isRead = false,
    this.kakaoUserId,
    this.kakaoNickname,
  });

  factory KakaoReservation.fromJson(Map<String, dynamic> json) {
    DateTime parseDate(dynamic value) {
      if (value == null) return DateTime.now();
      if (value is int) {
        // epoch millis
        return DateTime.fromMillisecondsSinceEpoch(value);
      }
      if (value is String) {
        // try ISO8601 or custom format
        try {
          return DateTime.parse(value);
        } catch (_) {
          try {
            return DateFormat('yyyy-MM-dd HH:mm:ss').parse(value);
          } catch (_) {
            return DateTime.now();
          }
        }
      }
      return DateTime.now();
    }

    DateTime? parseOptionalDate(dynamic value) {
      if (value == null) return null;
      try {
        return parseDate(value);
      } catch (_) {
        return null;
      }
    }

    return KakaoReservation(
      id: (json['id'] ?? json['reservationId'] ?? json['uuid'] ?? '').toString(),
      createdAt: parseDate(json['createdAt'] ?? json['created_at'] ?? json['timestamp']),
      name: json['name']?.toString(),
      studentName: json['studentName']?.toString() ?? json['student_name']?.toString(),
      phone: json['phone']?.toString() ?? json['phoneNumber']?.toString(),
      message: (json['message'] ?? json['text'] ?? json['utterance'] ?? '').toString(),
      desiredDateTime: parseOptionalDate(json['desiredDateTime'] ?? json['desired_time']),
      isRead: (json['isRead'] ?? json['read'] ?? false) == true,
      kakaoUserId: (json['kakaoUserId'] ?? json['userId'] ?? json['kakao_user_id'])?.toString(),
      kakaoNickname: (json['kakaoNickname'] ?? json['nickname'] ?? json['kakao_nickname'])?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'createdAt': createdAt.toIso8601String(),
      'name': name,
      'studentName': studentName,
      'phone': phone,
      'message': message,
      'desiredDateTime': desiredDateTime?.toIso8601String(),
      'isRead': isRead,
      'kakaoUserId': kakaoUserId,
      'kakaoNickname': kakaoNickname,
    };
  }
}





