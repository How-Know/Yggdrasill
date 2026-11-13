import 'dart:math' as math;
import 'dart:typed_data';

/// 학생 문항보기에서 단일 문항 PDF를 그리는 물리 폭.
///
/// 아이패드 미니 세로 화면에서 좌우 여백을 뺀 본문 폭이다.
const double questionViewWidthMm = 105;

/// 105mm가 화면에서 몇 논리 픽셀인지 정할 때 쓰는, 논리 픽셀 기준 인치당 밀도.
///
/// 아이패드는 패널 ppi를 포인트 배율로 나눈다. 그 외에는 모니터의 실제 ppi를
/// 같은 방식으로 나누고, 실제 크기를 모르면 96dpi 논리 픽셀로 둔다.
double questionViewLogicalPixelsPerInch({
  required bool useIosPanelPpi,
  required double devicePixelRatio,
  required double shortestPhysicalPixels,
  double? desktopPhysicalPpi,
}) {
  final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
  if (useIosPanelPpi) {
    final ppi = shortestPhysicalPixels < 1560 ? 326.0 : 264.0;
    return ppi / dpr;
  }
  final physical = desktopPhysicalPpi;
  if (physical != null && physical >= 72 && physical <= 800) {
    return physical / dpr;
  }
  return 96;
}

/// [maxWidth]보다 넓어지면 창 안쪽에 맞추고, 더 넓은 창에서는 [millimeters]를 유지한다.
double questionViewLogicalWidth({
  required double maxWidth,
  required double logicalPixelsPerInch,
  double millimeters = questionViewWidthMm,
}) {
  final target = millimeters / 25.4 * logicalPixelsPerInch;
  if (!maxWidth.isFinite || maxWidth <= 0) return target;
  return math.min(target, maxWidth);
}

/// EDID에서 패널의 가로·세로 밀리미터를 읽는다.
///
/// 첫 상세 타이밍의 이미지 크기를 쓰고, 없으면 최대 이미지 크기(cm)를 쓴다.
({int widthMm, int heightMm})? edidPanelSizeMm(List<int> edid) {
  if (edid.length < 128 || edid[0] != 0x00 || edid[1] != 0xFF) {
    return null;
  }
  final byteCount = math.min(edid.length, 128);
  for (var base = 54; base + 17 < byteCount; base += 18) {
    final clock = edid[base] | (edid[base + 1] << 8);
    if (clock == 0) continue;
    final widthMm = edid[base + 12] | ((edid[base + 14] & 0xF0) << 4);
    final heightMm = edid[base + 13] | ((edid[base + 14] & 0x0F) << 8);
    if (widthMm >= 80 && heightMm >= 50) {
      return (widthMm: widthMm, heightMm: heightMm);
    }
  }
  final widthCm = edid[21];
  final heightCm = edid[22];
  if (widthCm >= 8 && heightCm >= 5) {
    return (widthMm: widthCm * 10, heightMm: heightCm * 10);
  }
  return null;
}

/// `\\?\DISPLAY#SDC419C#5&...&UID256#{guid}` 에서 하드웨어 ID와 인스턴스를 뽑는다.
({String hardwareId, String instanceId})? parseDisplayInterfaceId(
  String deviceId,
) {
  final match = RegExp(
    r'DISPLAY#([^#]+)#([^#{]+)',
    caseSensitive: false,
  ).firstMatch(deviceId);
  if (match == null) return null;
  final hardwareId = match.group(1)?.trim() ?? '';
  final instanceId = match.group(2)?.trim() ?? '';
  if (hardwareId.isEmpty || instanceId.isEmpty) return null;
  return (hardwareId: hardwareId, instanceId: instanceId);
}

/// 모니터 픽셀 수와 EDID 크기로 가로 ppi를 만든다.
double? physicalPpiFromPanel({
  required int pixelWidth,
  required List<int> edid,
}) {
  if (pixelWidth < 320) return null;
  final size = edidPanelSizeMm(edid);
  if (size == null || size.widthMm <= 0) return null;
  final ppi = pixelWidth / (size.widthMm / 25.4);
  if (ppi < 72 || ppi > 800) return null;
  return ppi;
}

/// 테스트에서 EDID 바이트를 만들 때 쓴다.
Uint8List edidBytesForTest({
  required int widthMm,
  required int heightMm,
}) {
  final bytes = Uint8List(128);
  bytes[0] = 0x00;
  bytes[1] = 0xFF;
  bytes[54] = 0x01;
  bytes[66] = widthMm & 0xFF;
  bytes[67] = heightMm & 0xFF;
  bytes[68] = ((widthMm >> 4) & 0xF0) | ((heightMm >> 8) & 0x0F);
  return bytes;
}
