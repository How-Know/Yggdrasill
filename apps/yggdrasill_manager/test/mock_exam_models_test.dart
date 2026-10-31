import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/problem_bank/mock_exam/mock_exam_models.dart';

void main() {
  group('parseMockExamFileName', () {
    test('고3 문제지와 해설의 표기 변형을 모두 읽는다', () {
      final problem = parseMockExamFileName(r'C:\x\2024 고3 11월 수능 (확통).pdf')!;
      expect(problem.grade, 3);
      expect(problem.examYear, 2024);
      expect(problem.month, 11);
      expect(problem.org, 'csat');
      expect(problem.elective, 'probstats');
      expect(problem.kind, 'problem');

      for (final name in const <String>[
        '2024 고3 11월 수능 (확통) - 해설.pdf',
        '2024 고3 4월 교육청 (확통) -해설.pdf',
        '2025 고3 3월 교육청 (확통)_해설.pdf',
      ]) {
        final parsed = parseMockExamFileName(name);
        expect(parsed, isNotNull, reason: name);
        expect(parsed!.kind, 'solution', reason: name);
        expect(parsed.elective, 'probstats', reason: name);
      }
    });

    test('미적과 미적분을 같은 선택과목으로 본다', () {
      expect(parseMockExamFileName('2022 고3 6월 평가원 (미적분).pdf')!.elective, 'calculus');
      expect(parseMockExamFileName('2024 고3 6월 평가원 (미적).pdf')!.elective, 'calculus');
      expect(parseMockExamFileName('2024 고3 6월 평가원 (기하).pdf')!.org, 'kice');
    });

    test('고1·고2 는 선택과목 없이 읽고, 섞이면 거부한다', () {
      final g1 = parseMockExamFileName('2024 고1 3월 교육청 - 해설.pdf')!;
      expect(g1.grade, 1);
      expect(g1.elective, '');
      expect(g1.kind, 'solution');
      expect(parseMockExamFileName('2024 고3 3월 교육청.pdf'), isNull);
      expect(parseMockExamFileName('2024 고2 3월 교육청 (확통).pdf'), isNull);
      expect(parseMockExamFileName('2024 고3 3월 교육청 (확통).hwp'), isNull);
    });

    test('같은 시험의 문제지·해설은 시험 키가 같다', () {
      final a = parseMockExamFileName('2024 고3 11월 수능 (확통).pdf')!;
      final b = parseMockExamFileName('2024 고3 11월 수능 (기하) - 해설.pdf')!;
      expect(a.examKey, b.examKey);
      expect(a.paperKey, isNot(b.paperKey));
    });
  });

  test('학년도는 고3 만 시행연도 + 1', () {
    expect(mockExamSchoolYear(3, 2024), 2025);
    expect(mockExamSchoolYear(1, 2024), 2024);
  });

  test('문항 번호 범위', () {
    expect(mockExamExpectedNumbers(3, 'common'), hasLength(22));
    expect(mockExamExpectedNumbers(3, 'probstats').first, 23);
    expect(mockExamExpectedNumbers(1, 'common'), hasLength(30));
    expect(mockExamExpectedNumbers(1, 'probstats'), isEmpty);
  });

  test('정답 입력 정규화', () {
    expect(normalizeMockAnswerInput('3', objective: true)?.text, '③');
    expect(normalizeMockAnswerInput('③', objective: true)?.kind, 'objective');
    expect(normalizeMockAnswerInput('6', objective: true), isNull);
    expect(normalizeMockAnswerInput('064', objective: false)?.text, '64');
    expect(normalizeMockAnswerInput('', objective: false), isNull);
    expect(mockExamIsObjective(3, 15), isTrue);
    expect(mockExamIsObjective(3, 16), isFalse);
    expect(mockExamIsObjective(3, 28), isTrue);
    expect(mockExamIsObjective(1, 22), isFalse);
  });
}
