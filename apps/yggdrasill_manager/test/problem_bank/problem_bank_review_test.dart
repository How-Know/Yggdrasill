import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/problem_bank/problem_bank_models.dart';
import 'package:yggdrasill_manager/screens/problem_bank/review/problem_bank_review_mode.dart';
import 'package:yggdrasill_manager/screens/problem_bank/review/problem_bank_review_panes.dart';
import 'package:yggdrasill_manager/screens/problem_bank/widgets/problem_bank_question_card.dart';

ProblemBankDocument _document({
  String sourceType = 'school_past',
  bool textbookPdfOnly = false,
  bool hasHwpx = true,
  int? displayPageFrom,
  int? displayPageTo,
  int? rawPageFrom,
  int? rawPageTo,
}) {
  return ProblemBankDocument.fromMap(<String, dynamic>{
    'id': 'document-1',
    'academy_id': 'academy-1',
    'source_filename': 'source.pdf',
    'source_storage_bucket': 'problem-bank',
    'source_storage_path': hasHwpx ? 'source.hwpx' : '',
    'source_pdf_storage_bucket': 'problem-bank',
    'source_pdf_storage_path': 'source.pdf',
    'status': 'draft_ready',
    'source_type_code': sourceType,
    'meta': <String, dynamic>{
      if (textbookPdfOnly) 'extract_mode': 'textbook_pdf_only',
      if (displayPageFrom != null || displayPageTo != null)
        'textbook_scope': <String, dynamic>{
          'book_id': 'book-1',
          'book_name': 'RPM 1-1',
          'display_page_from': displayPageFrom,
          'display_page_to': displayPageTo,
          'raw_page_from': rawPageFrom,
          'raw_page_to': rawPageTo,
        },
    },
  });
}

ProblemBankQuestion _question({
  required String id,
  required int sourcePage,
  String documentId = 'document-1',
  int? displayPage,
  int? rawPage,
  bool checked = false,
  String? stem,
}) {
  return ProblemBankQuestion.fromMap(<String, dynamic>{
    'id': id,
    'question_uid': 'uid-$id',
    'academy_id': 'academy-1',
    'document_id': documentId,
    'source_page': sourcePage,
    'source_order': sourcePage,
    'question_number': '$sourcePage',
    'question_type': '객관식',
    'stem': stem ?? '$sourcePage쪽 문제',
    'choices': const <dynamic>[],
    'equations': const <dynamic>[],
    'figure_refs': const <dynamic>[],
    'confidence': 0.9,
    'is_checked': checked,
    'meta': <String, dynamic>{
      if (displayPage != null || rawPage != null)
        'textbook_crop_page': <String, dynamic>{
          'raw_page': rawPage ?? sourcePage,
          'display_page': displayPage,
        },
    },
  });
}

void main() {
  group('problemBankReviewModeOf', () {
    test('HWPX 시험지는 문서 검수 모드다', () {
      expect(
        problemBankReviewModeOf(_document()),
        ProblemBankReviewMode.examPaper,
      );
    });

    test('PDF-only 시중교재는 페이지 검수 모드다', () {
      expect(
        problemBankReviewModeOf(
          _document(
            sourceType: 'market_book',
            textbookPdfOnly: true,
            hasHwpx: false,
          ),
        ),
        ProblemBankReviewMode.textbookPdf,
      );
    });
  });

  group('textbook page mapping', () {
    test('표시 페이지를 우선하고 원본 페이지로 폴백한다', () {
      final display = _question(id: 'a', sourcePage: 3, displayPage: 12);
      final raw = _question(id: 'b', sourcePage: 4);
      expect(textbookDisplayPageOf(display), 12);
      expect(textbookDisplayPageOf(raw), 4);
      expect(
          textbookPagesOf(<ProblemBankQuestion>[display, raw]), <int>[4, 12]);
    });

    test('PDF 검수 페이지는 원본 PDF 페이지를 우선한다', () {
      final question = _question(
        id: 'a',
        sourcePage: 132,
        rawPage: 5,
        displayPage: 132,
      );
      expect(textbookPdfPageOf(question), 5);
      expect(textbookPdfPagesOf(<ProblemBankQuestion>[question]), <int>[5]);
    });

    test('페이지별 문항을 sourceOrder 순서로 반환한다', () {
      final questions = <ProblemBankQuestion>[
        _question(id: 'b', sourcePage: 2, displayPage: 11),
        _question(id: 'a', sourcePage: 1, displayPage: 11),
        _question(id: 'c', sourcePage: 3, displayPage: 12),
      ];
      expect(
        textbookQuestionsOnPage(questions, 11).map((q) => q.id),
        <String>['a', 'b'],
      );
    });

    test('문서의 교재 페이지 범위를 모두 만든다', () {
      final document = _document(
        sourceType: 'market_book',
        textbookPdfOnly: true,
        hasHwpx: false,
        displayPageFrom: 21,
        displayPageTo: 24,
      );
      expect(textbookDocumentPagesOf(document), <int>[21, 22, 23, 24]);
    });

    test('문서 이동은 표시 쪽수가 아닌 원본 PDF 범위를 사용한다', () {
      final document = _document(
        sourceType: 'market_book',
        textbookPdfOnly: true,
        hasHwpx: false,
        displayPageFrom: 132,
        displayPageTo: 133,
        rawPageFrom: 5,
        rawPageTo: 6,
      );
      expect(textbookDocumentPdfPagesOf(document), <int>[5, 6]);
    });
  });

  testWidgets('교재 페이지 탭은 선택한 페이지 문항과 검수 집계를 표시한다', (tester) async {
    final questions = <ProblemBankQuestion>[
      _question(id: 'a', sourcePage: 1, displayPage: 12, checked: true),
      _question(id: 'b', sourcePage: 2, displayPage: 13),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 520,
            height: 700,
            child: TextbookPageReviewPane(
              questions: questions,
              questionBuilder: (_, question) => Text(question.stem),
              panelColor: const Color(0xFF10171A),
              fieldColor: const Color(0xFF15171C),
              borderColor: const Color(0xFF223131),
              textColor: Colors.white,
              textSubColor: Colors.grey,
              accentColor: Colors.green,
            ),
          ),
        ),
      ),
    );

    expect(find.text('12쪽 · 1문항 · 검수 1 · 미검수 0'), findsOneWidget);
    expect(find.text('1쪽 문제'), findsOneWidget);
    expect(find.text('2쪽 문제'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('textbook-page-next')));
    await tester.pump();
    expect(find.text('13쪽 · 1문항 · 검수 0 · 미검수 1'), findsOneWidget);
    expect(find.text('2쪽 문제'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('textbook-page-input')),
      '12',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(find.text('12쪽 · 1문항 · 검수 1 · 미검수 0'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('textbook-page-input')),
      '99',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(find.text('해당 페이지에 추출 문항이 없습니다.'), findsOneWidget);
  });

  testWidgets('교재 페이지에서도 기존 카드 너비의 다열 Wrap을 사용한다', (tester) async {
    final questions = <ProblemBankQuestion>[
      _question(id: 'a', sourcePage: 1, rawPage: 12, displayPage: 12),
      _question(id: 'b', sourcePage: 2, rawPage: 12, displayPage: 12),
      _question(id: 'c', sourcePage: 3, rawPage: 12, displayPage: 12),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1100,
            height: 700,
            child: TextbookPageReviewPane(
              questions: questions,
              questionBuilder: (_, question) => Container(
                key: ValueKey('built-${question.id}'),
                height: question.id == 'b' ? 260 : 120,
                color: Colors.black,
              ),
              panelColor: const Color(0xFF10171A),
              fieldColor: const Color(0xFF15171C),
              borderColor: const Color(0xFF223131),
              textColor: Colors.white,
              textSubColor: Colors.grey,
              accentColor: Colors.green,
            ),
          ),
        ),
      ),
    );

    final firstX = tester.getTopLeft(find.byKey(const ValueKey('built-a'))).dx;
    final secondX = tester.getTopLeft(find.byKey(const ValueKey('built-b'))).dx;
    final thirdX = tester.getTopLeft(find.byKey(const ValueKey('built-c'))).dx;
    expect(<double>{firstX, secondX, thirdX}.length, greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('같은 표시 페이지의 서로 다른 문서 문항을 함께 표시한다', (tester) async {
    final questions = <ProblemBankQuestion>[
      _question(
        id: 'required-type',
        documentId: 'document-required-type',
        sourcePage: 20,
        displayPage: 13,
        stem: '필수유형 문항',
      ),
      _question(
        id: 'check',
        documentId: 'document-check',
        sourcePage: 20,
        displayPage: 13,
        stem: '확인체크 문항',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 600,
            child: TextbookPageReviewPane(
              questions: questions,
              initialPage: 13,
              questionBuilder: (_, question) => Text(question.stem),
              panelColor: const Color(0xFF10171A),
              fieldColor: const Color(0xFF15171C),
              borderColor: const Color(0xFF223131),
              textColor: Colors.white,
              textSubColor: Colors.grey,
              accentColor: Colors.green,
            ),
          ),
        ),
      ),
    );

    expect(find.text('13쪽 · 2문항 · 검수 0 · 미검수 2'), findsOneWidget);
    expect(find.text('필수유형 문항'), findsOneWidget);
    expect(find.text('확인체크 문항'), findsOneWidget);
  });

  testWidgets('현재 문서에 문항이 없어도 교재 전체 페이지로 이동을 요청한다', (tester) async {
    int? requestedPage;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 600,
            child: TextbookPageReviewPane(
              questions: <ProblemBankQuestion>[
                _question(
                  id: 'a',
                  sourcePage: 1,
                  rawPage: 12,
                  displayPage: 12,
                ),
              ],
              availablePages: const <int>[12, 13, 14],
              onPageRequested: (page) => requestedPage = page,
              questionBuilder: (_, question) => Text(question.stem),
              panelColor: const Color(0xFF10171A),
              fieldColor: const Color(0xFF15171C),
              borderColor: const Color(0xFF223131),
              textColor: Colors.white,
              textSubColor: Colors.grey,
              accentColor: Colors.green,
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('textbook-page-input')),
      '14',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(requestedPage, 14);
    expect(
      find.text('14쪽 · 0문항 · 검수 0 · 미검수 0'),
      findsOneWidget,
    );
  });

  testWidgets('원본 PDF 총 페이지가 있으면 1쪽부터 마지막 쪽까지 이동한다', (tester) async {
    int? requestedPage;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 600,
            child: TextbookPageReviewPane(
              questions: <ProblemBankQuestion>[
                _question(
                  id: 'a',
                  sourcePage: 1,
                  rawPage: 132,
                  displayPage: 132,
                ),
              ],
              availablePages: const <int>[132, 133],
              totalPageCount: 240,
              initialPage: 1,
              onPageRequested: (page) => requestedPage = page,
              questionBuilder: (_, question) => Text(question.stem),
              panelColor: const Color(0xFF10171A),
              fieldColor: const Color(0xFF15171C),
              borderColor: const Color(0xFF223131),
              textColor: Colors.white,
              textSubColor: Colors.grey,
              accentColor: Colors.green,
            ),
          ),
        ),
      ),
    );

    expect(
      find.text('1쪽 · 0문항 · 검수 0 · 미검수 0'),
      findsOneWidget,
    );
    expect(find.text('1 / 240 페이지'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('textbook-page-input')),
      '240',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(requestedPage, 240);
    expect(
      find.text('240쪽 · 0문항 · 검수 0 · 미검수 0'),
      findsOneWidget,
    );
    expect(find.text('240 / 240 페이지'), findsOneWidget);
  });

  testWidgets('긴 카드 내용은 좁은 폭에서도 overflow 없이 늘어난다', (tester) async {
    final longText = List<String>.filled(80, '긴 문항 본문').join(' ');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: SingleChildScrollView(
              child: ProblemBankQuestionCard(
                backgroundColor: Colors.black,
                borderColor: Colors.grey,
                child: Text(longText),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text(longText), findsOneWidget);
  });
}
