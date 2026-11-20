import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/textbook_api.dart';
import 'package:yggdrasill_student/services/textbook_catalog_organizer.dart';

StudentTextbook _book({
  required String id,
  required String name,
  required String gradeLabel,
  String series = '',
  int totalProblems = 100,
  int gradedCount = 0,
  int completedCount = 0,
  int seasonNo = 1,
  TextbookSeasonState seasonState = TextbookSeasonState.active,
  bool everCompleted = false,
}) {
  return StudentTextbook(
    bookId: id,
    gradeLabel: gradeLabel,
    name: name,
    description: '',
    colorValue: null,
    series: series,
    coverRef: '',
    totalProblems: totalProblems,
    gradedCount: gradedCount,
    correctCount: completedCount,
    completedCount: completedCount,
    firstWrongCount: 0,
    correctedCount: 0,
    stageProgress: const {},
    seasonNo: seasonNo,
    seasonState: seasonState,
    everCompleted: everCompleted,
  );
}

void main() {
  group('StudentTextbook.fromRow 기본 시즌 상태', () {
    test('처음 등록해 시즌 행과 풀이가 모두 없는 교재는 시작 전(notStarted)이 된다', () {
      final book = StudentTextbook.fromRow(const {
        'book_id': 'b-1',
        'grade_label': '공통수학1',
        'book_name': '쎈',
        'total_problems': 200,
        'graded_count': 0,
        'completed_count': 0,
      });
      expect(book.seasonState, TextbookSeasonState.notStarted);
      expect(book.isNotStarted, isTrue);
      expect(book.everCompleted, isFalse);
    });

    test('시즌 행이 없어도 기존 풀이 기록이 있는 교재는 활성(active) 상태를 유지한다', () {
      final book = StudentTextbook.fromRow(const {
        'book_id': 'b-2',
        'grade_label': '2-1',
        'book_name': '개념원리',
        'total_problems': 150,
        'graded_count': 12,
        'completed_count': 10,
      });
      expect(book.seasonState, TextbookSeasonState.active);
      expect(book.isActiveSeason, isTrue);
    });
  });

  group('시리즈별 가로 배치 및 과정 내림차순(왼쪽=상위 과정, 오른쪽=하위 과정)', () {
    test('같은 시리즈(쎈)끼리 묶이고 높은 과정이 왼쪽, 낮은 과정이 오른쪽에 온다', () {
      final books = [
        _book(id: '1', name: '쎈', gradeLabel: '2-1', series: 'ssen'),
        _book(id: '2', name: '쎈', gradeLabel: '대수', series: 'ssen'),
        _book(id: '3', name: '쎈', gradeLabel: '공통수학1', series: 'ssen'),
        _book(id: '4', name: '쎈', gradeLabel: '3-2', series: 'ssen'),
        _book(id: '5', name: '쎈', gradeLabel: '미적분1', series: 'ssen'),
        _book(id: '6', name: '쎈', gradeLabel: '공통수학2', series: 'ssen'),
      ];

      final rows = groupTextbooksBySeries(books);
      expect(rows, hasLength(1));
      expect(rows.single.seriesKey, 'ssen');
      expect(
        rows.single.books.map((b) => b.gradeLabel).toList(),
        ['미적분1', '대수', '공통수학2', '공통수학1', '3-2', '2-1'],
      );
    });

    test('중등·고등으로 시리즈 키가 갈린 동일 브랜드(개념원리, 고쟁이)도 한 줄로 묶인다', () {
      final books = [
        _book(
          id: 'w-mid',
          name: '개념원리 중학수학',
          gradeLabel: '3-1',
          series: 'wonri_middle',
        ),
        _book(
          id: 'w-high',
          name: '개념원리',
          gradeLabel: '공통수학1',
          series: 'wonri',
        ),
        _book(
          id: 'l-ssen',
          name: '라이트쎈',
          gradeLabel: '공통수학1',
          series: 'ssen',
        ),
      ];

      final rows = groupTextbooksBySeries(books);
      expect(rows, hasLength(2));
      final wonriRow = rows.firstWhere((r) => r.seriesKey == 'wonri');
      expect(
        wonriRow.books.map((b) => b.gradeLabel).toList(),
        ['공통수학1', '3-1'],
      );
      expect(rows.any((r) => r.seriesKey == 'light_ssen'), isTrue);
    });
  });

  group('organizeTextbooks 상태별 분류', () {
    test('활성 교재는 시리즈로 끊지 않고 개념서, 자습서, 연산서, 기본 유형서, 심화 문제집 순이다', () {
      final books = [
        _book(id: 'adv', name: '고쟁이', gradeLabel: '공통수학1', series: 'gojaengi'),
        _book(id: 'drill', name: '수력충전', gradeLabel: '2-1', series: 'suryeok'),
        _book(id: 'type-low', name: '쎈', gradeLabel: '2-1', series: 'ssen'),
        _book(id: 'concept', name: '개념원리', gradeLabel: '공통수학2', series: 'wonri'),
        _book(id: 'self', name: '수학 자습서', gradeLabel: '2-2', series: ''),
        _book(id: 'type-high', name: '쎈', gradeLabel: '공통수학1', series: 'ssen'),
      ];

      expect(
        sortActiveTextbooks(books).map((b) => b.bookId).toList(),
        ['concept', 'self', 'drill', 'type-high', 'type-low', 'adv'],
      );
    });

    test('활성·시작전·보류·종료됨·완료됨(한 번이라도 완주)으로 정확히 나뉜다', () {
      final activeSsen = _book(
        id: 'a1',
        name: '쎈',
        gradeLabel: '공통수학1',
        series: 'ssen',
        seasonState: TextbookSeasonState.active,
      );
      final notStartedSsen = _book(
        id: 'n1',
        name: '쎈',
        gradeLabel: '공통수학2',
        series: 'ssen',
        seasonState: TextbookSeasonState.notStarted,
      );
      final pausedBook = _book(
        id: 'p1',
        name: '고쟁이',
        gradeLabel: '공통수학1',
        series: 'gojaengi_high',
        seasonState: TextbookSeasonState.paused,
      );
      final endedPartial = _book(
        id: 'e1',
        name: '개념원리',
        gradeLabel: '2-2',
        series: 'wonri_middle',
        completedCount: 40,
        seasonState: TextbookSeasonState.closed,
        everCompleted: false,
      );
      // 시즌 1에서 완주한 뒤 시즌 2에서 30문제만 풀고 종료했어도 `완료됨`으로 간다.
      final completedOnce = _book(
        id: 'c1',
        name: '쎈',
        gradeLabel: '2-1',
        series: 'ssen',
        seasonNo: 2,
        completedCount: 30,
        seasonState: TextbookSeasonState.closed,
        everCompleted: true,
      );

      final organized = organizeTextbooks([
        notStartedSsen,
        pausedBook,
        endedPartial,
        completedOnce,
        activeSsen,
      ]);

      expect(organized.activeBooks, [activeSsen]);
      expect(organized.notStartedBooks, [notStartedSsen]);
      expect(organized.pausedBooks, [pausedBook]);
      expect(organized.endedBooks, [endedPartial]);
      expect(organized.completedBooks, [completedOnce]);
    });
  });
}
