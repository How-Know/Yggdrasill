import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_answer_service.dart';

// 수력충전 2-1 "실력 향상 테스트" 는 소단원 하나에 문항이 454개 붙는다. 정답을
// 통째로 보내면 게이트웨이가 413 answer_batch_too_large 로 거부해, 해설을 다
// 찾아 놓고도 "완료" 단추가 아무 반응 없는 것처럼 보였다.

void main() {
  TextbookAnswerUpload text(int i) => TextbookAnswerUpload(
        cropId: 'crop-$i',
        answerKind: 'subjective',
        answerText: '답 $i',
      );

  TextbookAnswerUpload image(int i, int bytes) => TextbookAnswerUpload(
        cropId: 'crop-$i',
        answerKind: 'image',
        answerText: '[image]',
        answerImagePngBytes: Uint8List(bytes),
      );

  test('한도 안이면 한 묶음으로 그대로 보낸다', () {
    final chunks = textbookAnswerUploadChunks(
      <TextbookAnswerUpload>[for (var i = 0; i < 12; i += 1) text(i)],
    );
    expect(chunks.length, 1);
    expect(chunks.first.length, 12);
    expect(chunks.first.first['crop_id'], 'crop-0');
  });

  test('454건은 건수 한도에 맞춰 잘리고 순서와 총합을 지킨다', () {
    final chunks = textbookAnswerUploadChunks(
      <TextbookAnswerUpload>[for (var i = 0; i < 454; i += 1) text(i)],
    );
    expect(chunks.length, 3);
    expect(chunks.map((c) => c.length).toList(), <int>[200, 200, 54]);
    final flat = <String>[
      for (final c in chunks) ...c.map((r) => '${r['crop_id']}')
    ];
    expect(flat.length, 454);
    expect(flat.first, 'crop-0');
    expect(flat.last, 'crop-453');
  });

  test('그림 정답은 건수가 적어도 바이트 한도에서 나뉜다', () {
    // 3MB PNG 는 base64 로 4MB 가 되어 두 건이면 6MB 한도를 넘는다.
    final chunks = textbookAnswerUploadChunks(
      <TextbookAnswerUpload>[
        for (var i = 0; i < 4; i += 1) image(i, 3 * 1024 * 1024)
      ],
    );
    expect(chunks.length, 4);
    for (final chunk in chunks) {
      expect(chunk.length, 1);
      expect(utf8.encode(jsonEncode(chunk)).length,
          lessThan(kAnswerBatchMaxBytes * 2));
    }
  });

  test('홀로 한도를 넘는 한 건도 버리지 않는다', () {
    final chunks = textbookAnswerUploadChunks(
      <TextbookAnswerUpload>[image(0, kAnswerBatchMaxBytes + 1024), text(1)],
    );
    expect(chunks.length, 2);
    expect(chunks[0].single['crop_id'], 'crop-0');
    expect(chunks[1].single['crop_id'], 'crop-1');
  });

  test('빈 목록은 묶음도 없다', () {
    expect(textbookAnswerUploadChunks(<TextbookAnswerUpload>[]), isEmpty);
  });
}
