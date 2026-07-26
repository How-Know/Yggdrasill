// 필기 획 → VLM 폴백용 PNG 렌더 재생 테스트.
//
// PencilInputPad 가 들고 있는 것과 같은 형식의 획("12" 필기)을 재생해
// 서버 2차 인식에 보낼 PNG 가 올바로 만들어지는지 확인한다.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/handwriting_ink_png.dart';

/// "12" 필기 픽스처 — 획 1 = 세로선("1"), 획 2 = "2" 모양 폴리라인.
List<List<Offset>> buildStrokesFixture() {
  return <List<Offset>>[
    <Offset>[
      const Offset(210.0, 60.0),
      const Offset(210.4, 90.0),
      const Offset(210.9, 120.0),
      const Offset(211.2, 150.0),
      const Offset(211.0, 175.0),
    ],
    <Offset>[
      const Offset(270.0, 80.0),
      const Offset(300.0, 62.0),
      const Offset(320.0, 85.0),
      const Offset(310.0, 120.0),
      const Offset(280.0, 150.0),
      const Offset(265.0, 172.0),
      const Offset(330.0, 172.0),
    ],
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('renderHandwritingPng', () {
    testWidgets('같은 필기 입력에서 고정 해상도 PNG 를 만든다', (tester) async {
      // toImage/PNG 인코딩은 실제 비동기 작업이라 runAsync 로 감싼다.
      await tester.runAsync(() async {
        final Uint8List? png = await renderHandwritingPng(
          strokes: buildStrokesFixture(),
          canvasSize: const Size(640, 220),
        );
        expect(png, isNotNull);

        // PNG 시그니처 확인.
        expect(png!.sublist(0, 8),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

        // 디코드해서 크기 확인 — 긴 변 1024px, 원본(640x220) 비율 유지.
        final codec = await ui.instantiateImageCodec(png);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 1024);
        expect(frame.image.height, (220.0 * 1024 / 640).round());

        // 흰 배경 위에 검정 획이 실제로 그려졌는지 픽셀로 확인.
        final data =
            await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        expect(data, isNotNull);
        final bytes = data!.buffer.asUint8List();
        var darkPixels = 0;
        var lightPixels = 0;
        for (var i = 0; i < bytes.length; i += 4) {
          if (bytes[i] < 64 && bytes[i + 1] < 64 && bytes[i + 2] < 64) {
            darkPixels++;
          } else if (bytes[i] > 220) {
            lightPixels++;
          }
        }
        expect(darkPixels, greaterThan(100));
        // 배경이 흰색으로 채워졌는지 (투명 배경이면 VLM 이 못 읽는다).
        expect(lightPixels, greaterThan(darkPixels));
        frame.image.dispose();
      });
    });

    testWidgets('획이 없으면 null 을 돌려준다', (tester) async {
      await tester.runAsync(() async {
        expect(
          await renderHandwritingPng(
            strokes: const <List<Offset>>[],
            canvasSize: const Size(640, 220),
          ),
          isNull,
        );
      });
    });

    testWidgets('캔버스 크기가 유효하지 않으면 null 을 돌려준다', (tester) async {
      await tester.runAsync(() async {
        expect(
          await renderHandwritingPng(
            strokes: buildStrokesFixture(),
            canvasSize: Size.zero,
          ),
          isNull,
        );
      });
    });
  });
}
