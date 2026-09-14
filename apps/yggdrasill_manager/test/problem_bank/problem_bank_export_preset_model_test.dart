import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/problem_bank/problem_bank_models.dart';
import 'package:yggdrasill_manager/screens/problem_bank/widgets/problem_bank_export_preset_dialog.dart';

void main() {
  test('문서 연결 필드와 갱신 시각을 파싱한다', () {
    final preset = ProblemBankExportPreset.fromMap(<String, dynamic>{
      'id': 'preset-1',
      'academy_id': 'academy-1',
      'display_name': '중간고사 양식',
      'preset_kind': 'settings',
      'paper_size': 'A4',
      'render_config': <String, dynamic>{},
      'selected_question_uids': <String>['q-1', 'q-2'],
      'source_document_id': 'document-1',
      'source_document_ids': <String>['document-1', 'document-2'],
      'document_id': 'saved-document-1',
      'source_document_name': '내신.hwpx',
      'updated_at': '2026-08-30T01:02:03Z',
    });

    expect(preset.sourceDocumentId, 'document-1');
    expect(preset.sourceDocumentIds, <String>['document-1', 'document-2']);
    expect(preset.documentId, 'saved-document-1');
    expect(preset.sourceDocumentName, '내신.hwpx');
    expect(preset.updatedAt, DateTime.utc(2026, 8, 30, 1, 2, 3));
  });

  test('연결된 복수 프리셋 중 updatedAt 기준 최신 항목을 선택한다', () {
    ProblemBankExportPreset preset(String id, String updatedAt) {
      return ProblemBankExportPreset.fromMap(<String, dynamic>{
        'id': id,
        'academy_id': 'academy-1',
        'display_name': id,
        'preset_kind': 'settings',
        'paper_size': 'A4',
        'render_config': <String, dynamic>{},
        'selected_question_uids': <String>['q-1'],
        'source_document_id': 'document-1',
        'updated_at': updatedAt,
      });
    }

    final latest = latestExportPresetForDocument(
      <ProblemBankExportPreset>[
        preset('older', '2026-08-29T00:00:00Z'),
        preset('latest', '2026-08-30T00:00:00Z'),
      ],
      'document-1',
    );

    expect(latest?.id, 'latest');
    expect(
      latestExportPresetForDocument(
        <ProblemBankExportPreset>[preset('other', '2026-08-30T00:00:00Z')],
        'document-missing',
      ),
      isNull,
    );
  });
}
