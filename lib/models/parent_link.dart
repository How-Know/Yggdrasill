import 'package:flutter/foundation.dart';

class ParentLink {
  final String id;
  final String? kakaoUserId;
  final String? phone;
  final String? matchedStudentId;
  final String? matchedStudentName;
  final String? matchedParentName;
  final DateTime? createdAt;
  final String? status; // e.g., linked, pending, failed

  ParentLink({
    required this.id,
    this.kakaoUserId,
    this.phone,
    this.matchedStudentId,
    this.matchedStudentName,
    this.matchedParentName,
    this.createdAt,
    this.status,
  });

  static String? _readStr(Map<String, dynamic> json, List<String> keys) {
    for (final k in keys) {
      final v = json[k];
      if (v == null) continue;
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  static DateTime? _readDate(Map<String, dynamic> json, List<String> keys) {
    for (final k in keys) {
      final v = json[k];
      if (v == null) continue;
      if (v is String && v.isNotEmpty) {
        try {
          return DateTime.parse(v);
        } catch (_) {}
      }
    }
    return null;
  }

  factory ParentLink.fromJson(Map<String, dynamic> json) {
    final id = _readStr(json, ['id', '_id', 'linkId']) ?? UniqueKey().toString();
    return ParentLink(
      id: id,
      kakaoUserId: _readStr(json, ['kakaoUserId', 'userId', 'kakao_user_id', 'kakaoid', 'user_id']),
      phone: _readStr(json, ['phone', 'phoneNumber', 'parentPhone', 'parent_phone', 'parentPhoneNumber']),
      matchedStudentId: _readStr(json, ['studentId', 'matchedStudentId']),
      matchedStudentName: _readStr(json, ['studentName', 'matchedStudentName']),
      matchedParentName: _readStr(json, ['parentName', 'matchedParentName']),
      createdAt: _readDate(json, ['createdAt', 'created_at']),
      status: _readStr(json, ['status', 'linkStatus']),
    );
  }

  ParentLink copyWith({
    String? id,
    String? kakaoUserId,
    String? phone,
    String? matchedStudentId,
    String? matchedStudentName,
    String? matchedParentName,
    DateTime? createdAt,
    String? status,
  }) {
    return ParentLink(
      id: id ?? this.id,
      kakaoUserId: kakaoUserId ?? this.kakaoUserId,
      phone: phone ?? this.phone,
      matchedStudentId: matchedStudentId ?? this.matchedStudentId,
      matchedStudentName: matchedStudentName ?? this.matchedStudentName,
      matchedParentName: matchedParentName ?? this.matchedParentName,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
    );
  }
}



