import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/display_physical_ppi.dart';
import 'package:yggdrasill_student/services/question_view_scale.dart';
import 'package:yggdrasill_student/services/windows_monitor_ppi.dart';

void main() {
  test('아이패드 미니는 326ppi를 포인트 배율로 나눈다', () {
    final logical = questionViewLogicalPixelsPerInch(
      useIosPanelPpi: true,
      devicePixelRatio: 2,
      shortestPhysicalPixels: 1488,
      desktopPhysicalPpi: null,
    );

    expect(logical, 163);
    expect(
      questionViewLogicalWidth(
        maxWidth: 744,
        logicalPixelsPerInch: logical,
      ),
      closeTo(105 / 25.4 * 163, 0.01),
    );
  });

  test('데스크톱은 패널 ppi를 배율로 나눈 105mm를 쓴다', () {
    const pixelWidth = 2880;
    const widthMm = 302;
    const ppi = pixelWidth / (widthMm / 25.4);
    final logical = questionViewLogicalPixelsPerInch(
      useIosPanelPpi: false,
      devicePixelRatio: 1.25,
      shortestPhysicalPixels: 1800,
      desktopPhysicalPpi: ppi,
    );
    final width = questionViewLogicalWidth(
      maxWidth: 2000,
      logicalPixelsPerInch: logical,
    );

    expect(width, closeTo(105 / widthMm * pixelWidth / 1.25, 0.05));
  });

  test('패널 크기를 모르면 96dpi로 둔다', () {
    final logical = questionViewLogicalPixelsPerInch(
      useIosPanelPpi: false,
      devicePixelRatio: 1.25,
      shortestPhysicalPixels: 1800,
      desktopPhysicalPpi: null,
    );

    expect(logical, 96);
  });

  test('EDID 상세 타이밍에서 패널 크기를 읽는다', () {
    final edid = edidBytesForTest(widthMm: 302, heightMm: 189);
    final size = edidPanelSizeMm(edid);

    expect(size?.widthMm, 302);
    expect(size?.heightMm, 189);
    expect(
      physicalPpiFromPanel(pixelWidth: 2880, edid: edid),
      closeTo(2880 / (302 / 25.4), 0.01),
    );
  });

  test('디스플레이 인터페이스 ID를 하드웨어 ID와 인스턴스로 나눈다', () {
    final parsed = parseDisplayInterfaceId(
      r'\\?\DISPLAY#SDC419C#5&31f6e02d&0&UID256#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}',
    );

    expect(parsed?.hardwareId, 'SDC419C');
    expect(parsed?.instanceId, '5&31f6e02d&0&UID256');
  });

  test('Win32 모니터 구조체 크기가 헤더와 같다', () {
    expect(windowsMonitorStructsMatchWin32, isTrue);
  }, skip: !Platform.isWindows);

  test('이 PC 모니터의 실제 ppi를 읽는다', () {
    final ppi = readDesktopPhysicalPpi();

    expect(ppi, isNotNull);
    expect(ppi!, inInclusiveRange(100, 400));
  }, skip: !Platform.isWindows);
}
