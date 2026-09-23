import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class M5OtaScheduleResult {
  const M5OtaScheduleResult({
    required this.deviceIds,
    required this.version,
  });

  final List<String> deviceIds;
  final String version;

  String get summaryLabel {
    if (deviceIds.isEmpty) return '대상 없음';
    if (deviceIds.length == 1) return _labelOf(deviceIds.first);
    return '${_labelOf(deviceIds.first)}부터 ${_labelOf(deviceIds.last)}까지';
  }

  static String _labelOf(String deviceId) {
    final match = RegExp(r'm5-device-(\d+)$').firstMatch(deviceId);
    if (match == null) return deviceId;
    return '${int.parse(match.group(1)!)}호기';
  }
}

class M5OtaException implements Exception {
  M5OtaException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 다음 부팅 때 이 PC의 펌웨어를 받도록 M5에 예약한다.
class M5OtaService {
  M5OtaService._();

  static const String testDeviceId = 'm5-device-001';
  static const int _port = 8091;
  static HttpServer? _server;
  static String? _servingPath;

  static List<String> get productionDeviceIds => [
        for (var number = 2; number <= 15; number++)
          'm5-device-${number.toString().padLeft(3, '0')}',
      ];

  static Future<M5OtaScheduleResult> scheduleTestDevice() {
    return scheduleDevices(const [testDeviceId]);
  }

  static Future<M5OtaScheduleResult> scheduleProductionDevices() {
    return scheduleDevices(productionDeviceIds);
  }

  static Future<M5OtaScheduleResult> scheduleDevices(
    List<String> deviceIds,
  ) async {
    if (deviceIds.isEmpty) {
      throw M5OtaException('업데이트할 기기가 없습니다.');
    }
    final root = _repoRoot();
    final firmwareDir = Directory(p.join(root, 'firmware', 'm5stack'));
    if (!firmwareDir.existsSync()) {
      throw M5OtaException('M5 펌웨어 폴더를 찾지 못했습니다.');
    }

    final ini = File(p.join(firmwareDir.path, 'platformio.ini'));
    final versionFile = File(p.join(firmwareDir.path, 'src', 'version.h'));
    final bin = File(
      p.join(firmwareDir.path, '.pio', 'build', 'm5-ota', 'firmware.bin'),
    );
    if (!bin.existsSync()) {
      throw M5OtaException('받을 펌웨어 파일이 없습니다. m5-ota 빌드가 필요합니다.');
    }

    final version = _readFirmwareVersion(versionFile);
    final academyId = _readAcademyId(ini.readAsStringSync());
    final host = await _lanHost();
    await _ensureServer(bin);
    final url = 'http://$host:$_port/firmware.bin';
    final payload = jsonEncode({
      'action': 'schedule',
      'version': version,
      'url': url,
    });
    await _mqttPublishAll([
      for (final deviceId in deviceIds)
        'academies/$academyId/devices/$deviceId/update',
    ], payload);
    return M5OtaScheduleResult(deviceIds: deviceIds, version: version);
  }

  static String _repoRoot() {
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final marker = Directory(p.join(dir.path, 'firmware', 'm5stack'));
      if (marker.existsSync()) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    throw M5OtaException('프로젝트 폴더를 찾지 못했습니다.');
  }

  static String _readFirmwareVersion(File file) {
    final match = RegExp(r'FIRMWARE_VERSION\s+"([^"]+)"')
        .firstMatch(file.readAsStringSync());
    if (match == null) {
      throw M5OtaException('펌웨어 버전을 읽지 못했습니다.');
    }
    return match.group(1)!;
  }

  static String _readAcademyId(String ini) {
    final match = RegExp(r'CFG_ACADEMY_ID=\\"([^"\\]+)\\"').firstMatch(ini);
    if (match == null) {
      throw M5OtaException('학원 아이디를 읽지 못했습니다.');
    }
    return match.group(1)!;
  }

  static Future<String> _lanHost() async {
    final addresses = <String>[];
    for (final iface in await NetworkInterface.list()) {
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        if (addr.isLoopback) continue;
        addresses.add(addr.address);
      }
    }
    if (addresses.contains('172.30.1.48')) return '172.30.1.48';
    for (final address in addresses) {
      if (address.startsWith('192.168.') ||
          address.startsWith('10.') ||
          address.startsWith('172.')) {
        return address;
      }
    }
    throw M5OtaException('M5가 접속할 이 PC의 주소를 찾지 못했습니다.');
  }

  static Future<void> _ensureServer(File bin) async {
    final path = bin.absolute.path;
    if (_server != null && _servingPath == path) return;
    await _server?.close(force: true);
    _servingPath = path;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
    _server = server;
    unawaited(server.forEach((request) async {
      try {
        if (request.uri.path != '/firmware.bin') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final file = File(path);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.binary;
        request.response.contentLength = await file.length();
        await request.response.addStream(file.openRead());
        await request.response.close();
      } catch (_) {
        try {
          await request.response.close();
        } catch (_) {}
      }
    }));
  }

  static Future<void> _mqttPublishAll(
    List<String> topics,
    String payload,
  ) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      1883,
      timeout: const Duration(seconds: 3),
    );
    try {
      final clientId = 'ygg-ota-${DateTime.now().millisecondsSinceEpoch}';
      socket.add(_mqttPacket(0x10, _connectBody(clientId)));
      await socket.flush();
      final connack = await socket.timeout(const Duration(seconds: 3)).first;
      if (connack.length < 4 || connack[0] != 0x20 || connack[3] != 0) {
        throw M5OtaException('MQTT 브로커에 연결하지 못했습니다.');
      }
      for (final topic in topics) {
        socket.add(_mqttPacket(0x30, _publishBody(topic, payload)));
      }
      await socket.flush();
    } on TimeoutException {
      throw M5OtaException('MQTT 브로커 응답이 없습니다. 이 PC의 브로커가 켜져 있는지 확인해 주세요.');
    } on SocketException {
      throw M5OtaException('MQTT 브로커에 연결하지 못했습니다.');
    } finally {
      socket.destroy();
    }
  }

  static List<int> _connectBody(String clientId) {
    final body = BytesBuilder();
    _addMqttString(body, 'MQTT');
    body.addByte(4);
    body.addByte(0x02);
    body.addByte(0);
    body.addByte(60);
    _addMqttString(body, clientId);
    return body.toBytes();
  }

  static List<int> _publishBody(String topic, String payload) {
    final body = BytesBuilder();
    _addMqttString(body, topic);
    body.add(utf8.encode(payload));
    return body.toBytes();
  }

  static void _addMqttString(BytesBuilder body, String value) {
    final bytes = utf8.encode(value);
    body.addByte(bytes.length >> 8);
    body.addByte(bytes.length & 0xff);
    body.add(bytes);
  }

  static List<int> _mqttPacket(int type, List<int> body) {
    return [type, ..._mqttRemainingLength(body.length), ...body];
  }

  static List<int> _mqttRemainingLength(int length) {
    final out = <int>[];
    var value = length;
    do {
      var digit = value % 128;
      value ~/= 128;
      if (value > 0) digit |= 0x80;
      out.add(digit);
    } while (value > 0);
    return out;
  }
}
