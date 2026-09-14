import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_solution_ref_service.dart';

void main() {
  test('해설 없음 업로드는 좌표 대신 명시적 none 상태를 보낸다', () {
    const upload = TextbookSolutionRefUpload(
      cropId: 'crop-244',
      rawPage: 0,
      numberRegion1k: <int>[0, 0, 0, 0],
      source: 'manual',
      sourceKind: 'none',
    );

    expect(upload.toJson(), <String, dynamic>{
      'crop_id': 'crop-244',
      'raw_page': 0,
      'number_region_1k': <int>[0, 0, 0, 0],
      'source': 'manual',
      'source_kind': 'none',
    });
  });
}
