// 필기 샘플 렌더 재생 테스트.
//
// 학생앱 PencilInputPad._buildSnapshot 이 업로드하는 것과 동일한 형식의
// payload(획 좌표·타이밍·압력·캔버스 크기)를 그대로 재생해,
// 파싱 → AI 판단용 오프스크린 PNG 렌더까지 전 과정이 동작하는지 확인한다.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/problem_bank/handwriting_sample_render.dart';

/// 학생앱이 "12"를 필기했을 때 올라가는 payload 와 같은 구조의 픽스처.
/// 획 1 = 세로선("1"), 획 2 = "2" 모양 폴리라인. t/p 는 실기기 형식 그대로.
Map<String, dynamic> buildStudentPayloadFixture() {
  return <String, dynamic>{
    'canvas_width': 640.0,
    'canvas_height': 220.0,
    'model': 'en-US',
    'recognized_candidates': <String>['l2', 'lz', '12'],
    'recognized_text': '12',
    'captured_at': '2026-07-26T01:00:00.000Z',
    'strokes': <Map<String, dynamic>>[
      <String, dynamic>{
        'x': <double>[210.0, 210.4, 210.9, 211.2, 211.0],
        'y': <double>[60.0, 90.0, 120.0, 150.0, 175.0],
        't': <int>[0, 30, 60, 90, 120],
        'p': <double>[0.4, 0.55, 0.6, 0.5, 0.3],
      },
      <String, dynamic>{
        'x': <double>[270.0, 300.0, 320.0, 310.0, 280.0, 265.0, 330.0],
        'y': <double>[80.0, 62.0, 85.0, 120.0, 150.0, 172.0, 172.0],
        't': <int>[400, 430, 470, 510, 550, 590, 630],
        'p': <double>[-1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0],
      },
    ],
    'submitted_answer': 'l2',
    'input_mode': 'pencil',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HandwritingInk.fromPayload', () {
    test('학생앱 payload 를 획·캔버스 정보로 파싱한다', () {
      final ink = HandwritingInk.fromPayload(buildStudentPayloadFixture());
      expect(ink.isEmpty, isFalse);
      expect(ink.strokes, hasLength(2));
      expect(ink.canvasWidth, 640.0);
      expect(ink.canvasHeight, 220.0);
      expect(ink.strokes.first.x, hasLength(5));
      expect(ink.strokes.last.y.last, 172.0);
    });

    test('획이 없거나 형식이 깨진 payload 는 빈 잉크가 된다', () {
      expect(HandwritingInk.fromPayload(const {}).isEmpty, isTrue);
      expect(
        HandwritingInk.fromPayload(const {
          'strokes': [
            {'x': [], 'y': []},
            'garbage',
          ],
        }).isEmpty,
        isTrue,
      );
    });
  });

  group('renderHandwritingInkPng', () {
    testWidgets('같은 필기 입력에서 고정 해상도 PNG 를 만든다', (tester) async {
      // toImage/PNG 인코딩은 실제 비동기 작업이라 runAsync 로 감싼다.
      await tester.runAsync(() async {
        final ink = HandwritingInk.fromPayload(buildStudentPayloadFixture());
        final Uint8List? png = await renderHandwritingInkPng(ink);
        expect(png, isNotNull);

        // PNG 시그니처 확인.
        expect(png!.sublist(0, 8),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

        // 디코드해서 크기 확인 — 긴 변 1200px, 원본(640x220) 비율 유지.
        final codec = await ui.instantiateImageCodec(png);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 1200);
        expect(frame.image.height, (220.0 * 1200 / 640).round());

        // 흰 배경 위에 검정 획이 실제로 그려졌는지 픽셀로 확인.
        final data =
            await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        expect(data, isNotNull);
        final bytes = data!.buffer.asUint8List();
        var darkPixels = 0;
        for (var i = 0; i < bytes.length; i += 4) {
          if (bytes[i] < 64 && bytes[i + 1] < 64 && bytes[i + 2] < 64) {
            darkPixels++;
          }
        }
        expect(darkPixels, greaterThan(100));
        frame.image.dispose();
      });
    });

    testWidgets('획이 없으면 null 을 돌려준다', (tester) async {
      await tester.runAsync(() async {
        expect(await renderHandwritingInkPng(HandwritingInk.empty), isNull);
      });
    });
  });
}
