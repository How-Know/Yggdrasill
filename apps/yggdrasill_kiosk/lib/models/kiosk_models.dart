typedef JsonMap = Map<String, dynamic>;

dynamic valueFor(JsonMap json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value != null) return value;
  }
  return null;
}

String stringFor(JsonMap json, List<String> keys, [String fallback = '']) {
  final value = valueFor(json, keys);
  return value == null ? fallback : value.toString();
}

bool boolFor(JsonMap json, List<String> keys, [bool fallback = false]) {
  final value = valueFor(json, keys);
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    return const {
      'true',
      '1',
      'yes',
      'checked_in',
      'completed',
    }.contains(value.toLowerCase());
  }
  return fallback;
}

JsonMap? mapFor(JsonMap json, List<String> keys) {
  final value = valueFor(json, keys);
  return value is Map ? Map<String, dynamic>.from(value) : null;
}

List<dynamic> listFor(JsonMap json, List<String> keys) {
  final value = valueFor(json, keys);
  if (value is List) return value;
  if (value is Map) {
    final nested = valueFor(Map<String, dynamic>.from(value), const [
      'items',
      'students',
      'results',
      'data',
    ]);
    if (nested is List) return nested;
  }
  return const [];
}

class KioskSession {
  const KioskSession({required this.deviceId, required this.token});
  final String deviceId;
  final String token;
}

class PairingState {
  const PairingState({
    required this.pairingId,
    required this.pin,
    this.expiresAt,
  });
  final String pairingId;
  final String pin;
  final DateTime? expiresAt;

  factory PairingState.fromJson(JsonMap json) {
    final source = mapFor(json, const ['data', 'pairing']) ?? json;
    return PairingState(
      pairingId: stringFor(source, const [
        'pairing_id',
        'pairingId',
        'request_id',
        'id',
      ]),
      pin: stringFor(source, const [
        'pairing_pin',
        'pairingPin',
        'pin',
        'code',
      ]),
      expiresAt: DateTime.tryParse(
        stringFor(source, const ['expires_at', 'expiresAt']),
      ),
    );
  }

  PairingState withPairingId(String value) =>
      PairingState(pairingId: value, pin: pin, expiresAt: expiresAt);
}

class Announcement {
  const Announcement({required this.title, required this.body});
  final String title;
  final String body;

  factory Announcement.fromJson(JsonMap json) => Announcement(
    title: stringFor(json, const ['title', 'subject', 'name'], '공지사항'),
    body: stringFor(json, const ['body', 'content', 'message', 'text']),
  );
}

class AcademyInfo {
  const AcademyInfo({required this.name, required this.address});
  final String name;
  final String address;
}

class BootstrapData {
  const BootstrapData({required this.academy, this.announcement});
  final AcademyInfo academy;
  final Announcement? announcement;

  factory BootstrapData.fromJson(JsonMap json) {
    final root = mapFor(json, const ['data', 'result']) ?? json;
    final academy =
        mapFor(root, const [
          'academy',
          'organization',
          'tenant',
          'institute',
        ]) ??
        const <String, dynamic>{};
    final rawAnnouncement = mapFor(root, const [
      'announcement',
      'active_announcement',
      'activeAnnouncement',
    ]);
    return BootstrapData(
      academy: AcademyInfo(
        name: stringFor(
          academy,
          const ['name', 'academy_name', 'academyName'],
          stringFor(root, const ['academy_name', 'academyName'], 'Yggdrasill'),
        ),
        address: stringFor(academy, const [
          'address',
          'road_address',
          'roadAddress',
          'location',
        ], stringFor(root, const ['academy_address', 'academyAddress'])),
      ),
      announcement:
          rawAnnouncement == null ||
              !boolFor(rawAnnouncement, const ['active', 'is_active'], true)
          ? null
          : Announcement.fromJson(rawAnnouncement),
    );
  }
}

class StudentVisit {
  const StudentVisit({
    required this.id,
    required this.name,
    required this.timeLabel,
    required this.checkedIn,
    required this.scheduledToday,
  });
  final String id;
  final String name;
  final String timeLabel;
  final bool checkedIn;
  final bool scheduledToday;

  StudentVisit copyWith({
    String? timeLabel,
    bool? checkedIn,
    bool? scheduledToday,
  }) => StudentVisit(
    id: id,
    name: name,
    timeLabel: timeLabel ?? this.timeLabel,
    checkedIn: checkedIn ?? this.checkedIn,
    scheduledToday: scheduledToday ?? this.scheduledToday,
  );

  factory StudentVisit.fromJson(JsonMap json) {
    final student = mapFor(json, const ['student', 'profile']) ?? json;
    var timeLabel = stringFor(json, const [
      'time',
      'scheduled_time',
      'scheduledTime',
      'start_time',
      'startTime',
      'lesson_time',
    ]);
    if (timeLabel.isEmpty) {
      final classDateTime = DateTime.tryParse(
        stringFor(json, const ['class_date_time', 'classDateTime']),
      )?.toLocal();
      if (classDateTime != null) {
        timeLabel =
            '${classDateTime.hour.toString().padLeft(2, '0')}:'
            '${classDateTime.minute.toString().padLeft(2, '0')}';
      }
    }
    return StudentVisit(
      id: stringFor(student, const [
        'id',
        'student_id',
        'studentId',
        'user_id',
      ], stringFor(json, const ['student_id', 'studentId', 'id'])),
      name: stringFor(student, const [
        'name',
        'student_name',
        'studentName',
        'display_name',
      ], stringFor(json, const ['student_name', 'studentName', 'name'], '학생')),
      timeLabel: timeLabel,
      checkedIn: boolFor(json, const [
        'checked_in',
        'checkedIn',
        'is_checked_in',
        'attending',
      ]),
      scheduledToday: boolFor(json, const [
        'scheduled_today',
        'scheduledToday',
        'is_scheduled',
      ], true),
    );
  }
}

class CheckInResult {
  const CheckInResult({
    required this.success,
    required this.message,
    this.code = '',
  });
  final bool success;
  final String message;
  final String code;

  factory CheckInResult.fromJson(JsonMap json) {
    final root = mapFor(json, const ['data', 'result']) ?? json;
    final success = boolFor(root, const ['success', 'ok', 'checked_in']);
    return CheckInResult(
      success: success,
      code: stringFor(root, const ['code', 'error_code', 'status']),
      message: stringFor(root, const [
        'message',
        'detail',
        'error_description',
        'error',
      ], success ? '등원이 완료되었습니다.' : '등원 처리에 실패했습니다.'),
    );
  }
}
