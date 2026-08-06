import '../problem_bank_models.dart';

enum ProblemBankReviewMode { examPaper, textbookPdf }

ProblemBankReviewMode problemBankReviewModeOf(ProblemBankDocument? document) {
  if (document == null) return ProblemBankReviewMode.examPaper;
  final sourceType = document.sourceTypeCode.trim().toLowerCase();
  final isTextbookSource = sourceType == 'market_book' ||
      sourceType == 'lecture_book' ||
      sourceType == 'ebs_book';
  final scope = _textbookScopeOf(document);
  final hasTextbookScope =
      '${scope['book_id'] ?? scope['book_name'] ?? ''}'.trim().isNotEmpty;
  if (document.isTextbookPdfOnly ||
      ((isTextbookSource || hasTextbookScope) &&
          document.hasPdfSource &&
          !document.hasHwpxSource)) {
    return ProblemBankReviewMode.textbookPdf;
  }
  return ProblemBankReviewMode.examPaper;
}

int textbookDisplayPageOf(ProblemBankQuestion question) {
  final cropPage = question.meta['textbook_crop_page'];
  if (cropPage is Map) {
    final displayPage = _positiveInt(cropPage['display_page']);
    if (displayPage != null) return displayPage;
    final rawPage = _positiveInt(cropPage['raw_page']);
    if (rawPage != null) return rawPage;
  }
  return question.sourcePage > 0 ? question.sourcePage : 1;
}

int textbookPdfPageOf(ProblemBankQuestion question) {
  final cropPage = question.meta['textbook_crop_page'];
  if (cropPage is Map) {
    final rawPage = _positiveInt(cropPage['raw_page']);
    if (rawPage != null) return rawPage;
    final displayPage = _positiveInt(cropPage['display_page']);
    if (displayPage != null) return displayPage;
  }
  return question.sourcePage > 0 ? question.sourcePage : 1;
}

List<int> textbookPagesOf(Iterable<ProblemBankQuestion> questions) {
  final pages = questions.map(textbookDisplayPageOf).toSet().toList()..sort();
  return pages;
}

List<int> textbookPdfPagesOf(Iterable<ProblemBankQuestion> questions) {
  final pages = questions.map(textbookPdfPageOf).toSet().toList()..sort();
  return pages;
}

List<int> textbookDocumentPagesOf(ProblemBankDocument document) {
  final scope = _textbookScopeOf(document);
  final displayFrom = _positiveInt(scope['display_page_from']);
  final displayTo = _positiveInt(scope['display_page_to']);
  final rawFrom = _positiveInt(scope['raw_page_from']);
  final rawTo = _positiveInt(scope['raw_page_to']);
  final from = displayFrom ?? rawFrom;
  final to = displayTo ?? rawTo;
  if (from == null || to == null) return const <int>[];
  final start = from < to ? from : to;
  final end = from < to ? to : from;
  return List<int>.generate(end - start + 1, (index) => start + index);
}

List<int> textbookDocumentPdfPagesOf(ProblemBankDocument document) {
  final scope = _textbookScopeOf(document);
  final rawFrom = _positiveInt(scope['raw_page_from']);
  final rawTo = _positiveInt(scope['raw_page_to']);
  final displayFrom = _positiveInt(scope['display_page_from']);
  final displayTo = _positiveInt(scope['display_page_to']);
  final from = rawFrom ?? displayFrom;
  final to = rawTo ?? displayTo;
  if (from == null || to == null) return const <int>[];
  final start = from < to ? from : to;
  final end = from < to ? to : from;
  return List<int>.generate(end - start + 1, (index) => start + index);
}

Map<String, dynamic> _textbookScopeOf(ProblemBankDocument document) {
  for (final raw in <dynamic>[
    document.meta['textbook_scope'],
    document.classificationDetail['textbook_scope'],
    document.meta['source_classification'] is Map
        ? (document.meta['source_classification'] as Map)['textbook']
        : null,
  ]) {
    if (raw is Map) {
      return raw.map((key, dynamic value) => MapEntry('$key', value));
    }
  }
  return const <String, dynamic>{};
}

List<ProblemBankQuestion> textbookQuestionsOnPage(
  Iterable<ProblemBankQuestion> questions,
  int page,
) {
  final result = questions
      .where((question) => textbookDisplayPageOf(question) == page)
      .toList();
  result.sort((a, b) {
    final byOrder = a.sourceOrder.compareTo(b.sourceOrder);
    if (byOrder != 0) return byOrder;
    return a.questionNumber.compareTo(b.questionNumber);
  });
  return result;
}

List<ProblemBankQuestion> textbookQuestionsOnPdfPage(
  Iterable<ProblemBankQuestion> questions,
  int page,
) {
  final result = questions
      .where((question) => textbookPdfPageOf(question) == page)
      .toList();
  result.sort((a, b) {
    final byOrder = a.sourceOrder.compareTo(b.sourceOrder);
    if (byOrder != 0) return byOrder;
    return a.questionNumber.compareTo(b.questionNumber);
  });
  return result;
}

int? _positiveInt(dynamic value) {
  final parsed = value is num ? value.toInt() : int.tryParse('$value'.trim());
  return parsed != null && parsed > 0 ? parsed : null;
}
