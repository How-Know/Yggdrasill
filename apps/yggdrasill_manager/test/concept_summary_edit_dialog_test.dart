import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_summary_edit_dialog.dart';
import 'package:yggdrasill_manager/services/concept_draft_models.dart';
import 'package:yggdrasill_manager/services/concept_service.dart';

void main() {
  testWidgets('개념 수정 창은 있던 유형만 고르고 기호·레벨·구분 둘은 없다', (tester) async {
    const concept = ConceptItem(
      id: '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b',
      kind: ConceptKind.definition,
      subType: '정의',
      name: '소수',
      content: '1과 자신으로만 나누어진다',
      level: 2,
      symbol: 'p',
    );
    const types = [
      ConceptTypeInfo(name: '정의', description: '', legacySubType: '정의'),
      ConceptTypeInfo(name: '주의', description: '', legacySubType: '정리'),
      ConceptTypeInfo(name: '연산', description: '', legacySubType: '연산'),
    ];
    ConceptSummaryEdit? saved;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final request = await showConceptSummaryEditDialog(
                context,
                concept: concept,
                types: types,
                currentType: '정의',
              );
              saved = request?.edit;
            },
            child: const Text('열기'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    expect(find.text('기호 (선택)'), findsNothing);
    expect(find.text('레벨'), findsNothing);
    expect(find.text('세부 유형'), findsNothing);
    expect(find.text('구분'), findsNothing);
    expect(find.text('정의'), findsOneWidget);
    expect(find.text('주의'), findsOneWidget);
    expect(find.text('연산'), findsOneWidget);
    expect(find.byKey(const ValueKey('concept-edit-delete')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('concept-edit-type-주의')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('concept-edit-name')), '소수란');
    await tester.tap(find.byKey(const ValueKey('concept-edit-save')));
    await tester.pumpAndSettle();

    expect(saved?.name, '소수란');
    expect(saved?.content, concept.content);
    expect(saved?.typeName, '주의');
    expect(tester.takeException(), isNull);
  });
}
