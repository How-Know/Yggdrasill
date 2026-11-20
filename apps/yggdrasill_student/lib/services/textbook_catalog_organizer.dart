import 'textbook_api.dart';

/// 한 시리즈의 가로 카드 줄(왼쪽이 높은 과정, 오른쪽이 낮은 과정).
class TextbookSeriesRow {
  const TextbookSeriesRow({
    required this.seriesKey,
    required this.books,
  });

  final String seriesKey;
  final List<StudentTextbook> books;
}

/// 교재 목록 화면의 상태별·시리즈별 정리 결과.
class OrganizedTextbooks {
  const OrganizedTextbooks({
    required this.activeBooks,
    required this.notStartedBooks,
    required this.pausedBooks,
    required this.endedBooks,
    required this.completedBooks,
    required this.notStartedSeries,
    required this.pausedSeries,
    required this.endedSeries,
    required this.completedSeries,
  });

  final List<StudentTextbook> activeBooks;
  final List<StudentTextbook> notStartedBooks;
  final List<StudentTextbook> pausedBooks;
  final List<StudentTextbook> endedBooks;
  final List<StudentTextbook> completedBooks;

  final List<TextbookSeriesRow> notStartedSeries;
  final List<TextbookSeriesRow> pausedSeries;
  final List<TextbookSeriesRow> endedSeries;
  final List<TextbookSeriesRow> completedSeries;
}

OrganizedTextbooks organizeTextbooks(List<StudentTextbook> books) {
  final active = <StudentTextbook>[];
  final notStarted = <StudentTextbook>[];
  final paused = <StudentTextbook>[];
  final ended = <StudentTextbook>[];
  final completed = <StudentTextbook>[];

  for (final book in books) {
    switch (book.seasonState) {
      case TextbookSeasonState.active:
        active.add(book);
      case TextbookSeasonState.notStarted:
        notStarted.add(book);
      case TextbookSeasonState.paused:
        paused.add(book);
      case TextbookSeasonState.closed:
        if (book.everCompleted) {
          completed.add(book);
        } else {
          ended.add(book);
        }
    }
  }

  return OrganizedTextbooks(
    activeBooks: sortActiveTextbooks(active),
    notStartedBooks: sortActiveTextbooks(notStarted),
    pausedBooks: paused,
    endedBooks: ended,
    completedBooks: completed,
    notStartedSeries: groupTextbooksBySeries(notStarted),
    pausedSeries: groupTextbooksBySeries(paused),
    endedSeries: groupTextbooksBySeries(ended),
    completedSeries: groupTextbooksBySeries(completed),
  );
}

/// 활성 교재 나열 순서. 시리즈로 끊지 않고 교재 종류 순으로 한 줄에 잇는다.
///
/// 개념서 → 자습서 → 연산서 → 기본 유형서 → 심화 문제집.
/// 같은 종류 안에서는 과정이 높은 교재가 왼쪽이다.
List<StudentTextbook> sortActiveTextbooks(List<StudentTextbook> books) {
  final sorted = List<StudentTextbook>.of(books);
  sorted.sort((a, b) {
    final kind = textbookKindOrder(a).compareTo(textbookKindOrder(b));
    if (kind != 0) return kind;
    return compareTextbooksHigherCourseFirst(a, b);
  });
  return sorted;
}

/// 교재 종류 순서. 분류되지 않은 교재는 심화 문제집 뒤에 둔다.
int textbookKindOrder(StudentTextbook book) {
  final series = book.series.trim().toLowerCase();
  final compact = book.name
      .trim()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('＋', '+')
      .replaceAll('ＲＰＭ', 'RPM');
  final lower = compact.toLowerCase();

  if (compact.contains('자습') || lower.contains('jasup')) return 1;

  if (series == 'suryeok' ||
      compact.contains('수력충전') ||
      compact.contains('연산') ||
      lower.contains('suryeok')) {
    return 2;
  }

  if (series == 'gojaengi' ||
      series == 'gojaengi_high' ||
      compact.contains('고쟁이') ||
      compact.contains('블랙라벨') ||
      compact.contains('일품') ||
      compact.contains('자이스토리') ||
      compact.contains('마플시너지') ||
      compact.contains('고난도') ||
      compact.contains('최상위') ||
      lower.contains('gojaengi')) {
    return 4;
  }

  if (series == 'ssen' ||
      series == 'rpm' ||
      compact.contains('쎈') ||
      compact.contains('알피엠') ||
      compact.contains('마플교과서') ||
      lower.contains('ssen') ||
      lower.contains('rpm')) {
    return 3;
  }

  if (series == 'wonri' ||
      series == 'wonri_middle' ||
      series == 'gaeyu' ||
      series == 'gaeyu_high' ||
      compact.contains('개념원리') ||
      compact.contains('개념+유형') ||
      compact.contains('개념플러스유형') ||
      lower.contains('wonri') ||
      lower.contains('gaeyu')) {
    return 0;
  }

  return 5;
}

/// 같은 시리즈(쎈, 개념원리, 고쟁이 등)끼리 묶고,
/// 한 시리즈 안에서는 과정이 높은 교재가 왼쪽, 낮은 교재가 오른쪽에 오도록 정렬한다.
List<TextbookSeriesRow> groupTextbooksBySeries(List<StudentTextbook> books) {
  if (books.isEmpty) return const <TextbookSeriesRow>[];

  final grouped = <String, List<StudentTextbook>>{};
  for (final book in books) {
    final key = textbookSeriesGroupKey(book);
    grouped.putIfAbsent(key, () => <StudentTextbook>[]).add(book);
  }

  final rows = <TextbookSeriesRow>[];
  for (final entry in grouped.entries) {
    final sorted = List<StudentTextbook>.of(entry.value)
      ..sort(compareTextbooksHigherCourseFirst);
    rows.add(TextbookSeriesRow(seriesKey: entry.key, books: sorted));
  }

  rows.sort((a, b) {
    final aTop = textbookCourseRank(a.books.first.gradeLabel);
    final bTop = textbookCourseRank(b.books.first.gradeLabel);
    final byRank = bTop.compareTo(aTop);
    if (byRank != 0) return byRank;
    return a.books.first.name.compareTo(b.books.first.name);
  });

  return rows;
}

int compareTextbooksHigherCourseFirst(StudentTextbook a, StudentTextbook b) {
  final rankCompare =
      textbookCourseRank(b.gradeLabel).compareTo(textbookCourseRank(a.gradeLabel));
  if (rankCompare != 0) return rankCompare;
  final nameCompare = a.name.compareTo(b.name);
  if (nameCompare != 0) return nameCompare;
  return b.gradeLabel.compareTo(a.gradeLabel);
}

/// 시리즈 식별 키. 중등/고등으로 나뉜 동일 브랜드(`wonri_middle`·`wonri` 등)도 하나로 묶고,
/// `라이트쎈`·`베이직쎈`·`RPM`처럼 별개 라인업은 구분한다.
String textbookSeriesGroupKey(StudentTextbook book) {
  final series = book.series.trim().toLowerCase();
  final compact = book.name
      .trim()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('＋', '+')
      .replaceAll('ＲＰＭ', 'RPM');
  final lower = compact.toLowerCase();

  if (compact.contains('라이트쎈') || lower.contains('lightssen')) {
    return 'light_ssen';
  }
  if (compact.contains('베이직쎈') || lower.contains('basicssen')) {
    return 'basic_ssen';
  }
  if (series == 'rpm' ||
      lower.contains('rpm') ||
      compact.contains('알피엠')) {
    return 'rpm';
  }
  if (series == 'ssen' || compact.contains('쎈') || lower.contains('ssen')) {
    return 'ssen';
  }
  if (series == 'wonri' ||
      series == 'wonri_middle' ||
      compact.contains('개념원리') ||
      lower.contains('wonri')) {
    return 'wonri';
  }
  if (series == 'gaeyu' ||
      series == 'gaeyu_high' ||
      compact.replaceAll('+', '').contains('개념유형') ||
      compact.contains('개념플러스유형') ||
      lower.contains('gaeyu')) {
    return 'gaeyu';
  }
  if (series == 'gojaengi' ||
      series == 'gojaengi_high' ||
      compact.contains('고쟁이') ||
      lower.contains('gojaengi')) {
    return 'gojaengi';
  }
  if (series == 'suryeok' ||
      compact.contains('수력충전') ||
      lower.contains('suryeok')) {
    return 'suryeok';
  }
  if (compact.contains('마플시너지')) return 'maple_synergy';
  if (compact.contains('마플교과서')) return 'maple_textbook';
  if (compact.contains('일품')) return 'ilpum';
  if (compact.contains('블랙라벨')) return 'black_label';
  if (compact.contains('자이스토리')) return 'xistory';
  if (compact.contains('마더텅')) return 'mothertongue';
  if (series.isNotEmpty) return series;

  // 교재명 뒤에 과정명이 붙어 있는 경우 앞쪽 시리즈명만 남긴다.
  final stripped = _stripTrailingCourseToken(compact);
  if (stripped.isNotEmpty) return 'name:$stripped';
  return 'book:${book.bookId}';
}

String _stripTrailingCourseToken(String compactName) {
  return compactName.replaceFirst(
    RegExp(
      r'(초[1-6]-[12]|중?[1-3]-[12]|고[1-3](?:-[12])?|공통수학[12]|고등수학\([상하]\)|수학\([상하]\)|수학[12ⅠⅡ]|대수|미적분[12ⅠⅡ]?|확률과통계|확통|기하)$',
    ),
    '',
  );
}

/// 교육과정 단계 점수 (높을수록 상위 과정 → 왼쪽 배치).
int textbookCourseRank(String rawGradeLabel) {
  final normalized = rawGradeLabel
      .trim()
      .replaceAll(' ', '')
      .replaceAll('Ⅰ', '1')
      .replaceAll('Ⅱ', '2')
      .replaceAll('Ⅲ', '3')
      .replaceAll('（', '(')
      .replaceAll('）', ')');
  if (normalized.isEmpty) return 0;
  final lower = normalized.toLowerCase();

  // 공통수학1·2는 부분문자열 '수학1'·'수학2'를 포함하므로 먼저 판정한다.
  if (normalized.contains('공통수학2') ||
      normalized.contains('공수2') ||
      normalized.contains('수학(하)') ||
      normalized.contains('수학하') ||
      normalized == '고1-2' ||
      lower == 'h1-2') {
    return 312;
  }
  if (normalized.contains('공통수학1') ||
      normalized.contains('공수1') ||
      normalized.contains('수학(상)') ||
      normalized.contains('수학상') ||
      normalized == '고1-1' ||
      lower == 'h1-1') {
    return 311;
  }

  // 고등 심화·진로·선택 (위 → 아래)
  if (normalized.contains('미적분2') || normalized.contains('미적2')) {
    return 345;
  }
  if ((normalized.contains('미적분') || normalized.contains('미적')) &&
      !normalized.contains('미적분1') &&
      !normalized.contains('미적1')) {
    return 342;
  }
  if (normalized.contains('기하')) {
    return 338;
  }
  if (normalized.contains('확률과통계') ||
      normalized.contains('확률통계') ||
      normalized.contains('확통')) {
    return 334;
  }
  if (normalized == '고3' || lower == 'h3') {
    return 330;
  }
  if (normalized.contains('미적분1') ||
      normalized.contains('미적1') ||
      normalized.contains('수학2') ||
      normalized == '수2') {
    return 324;
  }
  if (normalized.contains('대수') ||
      normalized.contains('수학1') ||
      normalized == '수1') {
    return 321;
  }
  if (normalized == '고2' || lower == 'h2') {
    return 320;
  }
  if (normalized == '고1' || lower == 'h1') {
    return 310;
  }

  // 초등 (명시적 '초'/'e' 접두사 또는 4~6학년 학기 표기)
  final elemTerm =
      RegExp(r'^(?:초|초등|초등수학|e)([1-6])-([12])$').firstMatch(lower);
  if (elemTerm != null) {
    final g = int.parse(elemTerm.group(1)!);
    final t = int.parse(elemTerm.group(2)!);
    return 100 + g * 10 + t;
  }
  final elemGrade = RegExp(r'^(?:초|초등|e)([1-6])$').firstMatch(lower);
  if (elemGrade != null) {
    return 100 + int.parse(elemGrade.group(1)!) * 10;
  }
  final bareElemTerm = RegExp(r'^([4-6])-([12])$').firstMatch(lower);
  if (bareElemTerm != null) {
    final g = int.parse(bareElemTerm.group(1)!);
    final t = int.parse(bareElemTerm.group(2)!);
    return 100 + g * 10 + t;
  }

  // 중등 ('1-1'~'3-2', '중1-1'~'중3-2', 'm1-1'~'m3-2')
  final midTerm =
      RegExp(r'^(?:중|중학|중학수학|m)?([1-3])-([12])$').firstMatch(lower);
  if (midTerm != null) {
    final g = int.parse(midTerm.group(1)!);
    final t = int.parse(midTerm.group(2)!);
    return 200 + g * 10 + t;
  }
  final midGrade = RegExp(r'^(?:중|중학|m)([1-3])$').firstMatch(lower);
  if (midGrade != null) {
    return 200 + int.parse(midGrade.group(1)!) * 10;
  }

  return 0;
}
