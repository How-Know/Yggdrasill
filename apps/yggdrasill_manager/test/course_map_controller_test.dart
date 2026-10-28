import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/course_map_controller.dart';
import 'package:yggdrasill_manager/services/course_map_service.dart';

import 'course_map_fake.dart';

const _units = [
  U('다항식', [
    U('다항식의 연산', [U('덧셈과 뺄셈'), U('곱셈')]),
    U('나머지정리', [U('항등식'), U('나머지정리')]),
  ]),
  U('방정식과 부등식', [
    U('복소수', [U('복소수의 뜻')]),
  ]),
];

(FakeCourseMapBackend, String) _seed() {
  final b = FakeCourseMapBackend();
  final id = b.addCourse('공통수학1', key: 'H1', units: _units);
  b.addCourse('공통수학2', key: 'H2', units: const [U('도형의 방정식')]);
  return (b, id);
}

CourseMapController _controller(FakeCourseMapBackend b) {
  var n = 0;
  return CourseMapController.forTest(b, newId: () => 'n${++n}');
}

Future<(FakeCourseMapBackend, String, CourseMapController)> _loaded() async {
  final (b, id) = _seed();
  final c = _controller(b);
  await c.loadList();
  return (b, id, c);
}

void main() {
  group('편집본', () {
    test('이름·순서·옮기기를 해도 id는 그대로이고 저장 목록은 위에서 아래 순서다', () async {
      final (b, id, c) = await _loaded();
      final d = c.draft!;
      final ops = b.unitId(id, '다항식의 연산');
      final rest = b.unitId(id, '나머지정리');
      final complex = b.unitId(id, '복소수');

      c.rename(ops, '다항식의 계산');
      c.moveUnit(rest, -1);
      expect(c.reparent(complex, b.unitId(id, '다항식')), isNull);

      final payload = c.draft!.payload();
      expect(payload.map((u) => u.name).toList(), [
        '다항식',
        '나머지정리',
        '항등식',
        '나머지정리',
        '다항식의 계산',
        '덧셈과 뺄셈',
        '곱셈',
        '복소수',
        '복소수의 뜻',
        '방정식과 부등식',
      ]);
      expect(payload.firstWhere((u) => u.id == complex).parentId, b.unitId(id, '다항식'));
      expect(payload.map((u) => u.id).toSet().length, payload.length, reason: '같은 단원이 두 번 들어가지 않는다');
      expect(d.isRenamed(ops), isTrue);
      expect(d.isMoved(rest), isTrue);
      expect(d.isMoved(complex), isTrue);
      expect(d.numberLabel(complex), '3.', reason: '번호는 순서로 셀 뿐이다');
      expect(b.writes, 0);
    });

    test('바꿨다가 되돌리면 저장할 것이 없다', () async {
      final (b, id, c) = await _loaded();
      final rest = b.unitId(id, '나머지정리');
      c.rename(rest, '나머지 정리');
      c.rename(rest, '나머지정리');
      c.moveUnit(rest, -1);
      c.moveUnit(rest, 1);
      expect(c.draft!.dirty, isFalse);
      expect(c.isDirty(id), isFalse);
    });

    test('자기 아래로·세 단계를 넘는 곳으로는 옮기지 않는다', () async {
      final (b, id, c) = await _loaded();
      final d = c.draft!;
      final poly = b.unitId(id, '다항식');
      final ops = b.unitId(id, '다항식의 연산');
      final eq = b.unitId(id, '방정식과 부등식');

      expect(d.whyCannotReparent(poly, ops), contains('자기 자신이나 자기 아래'));
      expect(d.whyCannotReparent(poly, poly), contains('자기 자신이나 자기 아래'));
      expect(d.whyCannotReparent(ops, b.unitId(id, '복소수')), contains('세 단계'));
      expect(d.whyCannotReparent(poly, eq), contains('세 단계'), reason: '대단원 아래 소단원까지 있으면 한 단계 내려갈 수 없다');
      expect(d.whyCannotReparent(ops, eq), isNull);
      expect(d.whyCannotReparent(b.unitId(id, '곱셈'), null), isNull);

      expect(c.reparent(poly, ops), isNotNull);
      expect(c.draft!.node(poly)!.parentId, isNull, reason: '막힌 옮기기는 아무것도 바꾸지 않는다');
      expect(c.addUnit(b.unitId(id, '곱셈')), isNull, reason: '소단원 아래에는 더 넣지 않는다');
      expect(c.draft!.dirty, isFalse);
    });

    test('저장된 단원을 빼면 아래 단원까지 보관 목록에, 새 단원은 바로 없어진다', () async {
      final (b, id, c) = await _loaded();
      final ops = b.unitId(id, '다항식의 연산');
      final fresh = c.addUnit(ops)!;
      expect(c.draft!.node(fresh)!.isNew, isTrue);

      expect(c.removeUnit(ops), 3, reason: '중단원 하나와 소단원 둘');
      final d = c.draft!;
      expect(d.archive, {ops, b.unitId(id, '덧셈과 뺄셈'), b.unitId(id, '곱셈')});
      expect(d.node(fresh), isNull);
      expect(d.payload().any((u) => u.id == fresh || d.archive.contains(u.id)), isFalse);

      final another = c.addUnit(null)!;
      expect(c.removeUnit(another), 0);
      expect(c.draft!.archive.length, 3);
      expect(c.draft!.newCount, 0);
    });

    test('단계 번호는 아래 단원이 없는 단원에만 1부터 붙고 위 단원은 범위다', () async {
      final (b, id, c) = await _loaded();
      final steps = c.draft!.steps();
      expect(steps[b.unitId(id, '덧셈과 뺄셈')], (1, 1));
      expect(steps[b.unitId(id, '다항식의 연산')], (1, 2));
      expect(steps[b.unitId(id, '다항식')], (1, 4));
      expect(steps[b.unitId(id, '복소수의 뜻')], (5, 5));
      expect(courseMapRoman(4), 'IV');
      expect(courseMapRoman(9), 'IX');
    });
  });

  group('읽기·저장', () {
    test('처음 과정을 고르고 그 과정만 읽는다. 읽지 못하면 다른 목록으로 대신하지 않는다', () async {
      final (b, id, c) = await _loaded();
      expect(c.listLoaded, isTrue);
      expect(c.selectedCourseId, id);
      expect(c.activeCourses.map((x) => x.name), ['공통수학1', '공통수학2']);
      expect(c.activeCourses.first.counts, [2, 3, 5]);

      final broken = FakeCourseMapBackend()..failList = CourseMapException('course_map_forbidden', '권한 없음');
      final e = _controller(broken);
      await e.loadList();
      expect(e.listLoaded, isFalse);
      expect(e.listError?.code, 'course_map_forbidden');
      expect(e.courses, isEmpty);
      expect(b.writes, 0);
    });

    test('저장하면 같은 id로 남고 판이 오르며, 선택·펼침이 남는다', () async {
      final (b, id, c) = await _loaded();
      final ops = b.unitId(id, '다항식의 연산');
      final poly = b.unitId(id, '다항식');
      c.selectUnit(ops);
      c.toggleExpanded(poly);
      c.rename(ops, '다항식의 계산');
      final fresh = c.addUnit(ops)!;
      c.rename(fresh, '나눗셈');
      c.selectUnit(ops);

      expect(await c.save(), isTrue);
      expect(b.version(id), 2);
      expect(b.unitName(ops), '다항식의 계산');
      expect(b.parentOf('n1'), ops, reason: '새 단원은 화면에서 만든 id 그대로 저장된다');
      final d = c.draft!;
      expect(d.dirty, isFalse);
      expect(d.course.version, 2);
      expect(d.selectedId, ops);
      expect(d.expanded.contains(poly), isFalse, reason: '접어 둔 단원은 접힌 채로');
      expect(d.node(fresh)!.isNew, isFalse);
      expect(c.activeCourses.first.counts, [2, 3, 6]);
    });

    test('저장에 실패하면 편집이 그대로 남고 저장된 것처럼 보이지 않는다', () async {
      final (b, id, c) = await _loaded();
      final ops = b.unitId(id, '다항식의 연산');
      c.rename(ops, '다항식의 계산');
      b.bumpVersion(id);

      expect(await c.save(), isFalse);
      expect(c.saveError(id)?.stale, isTrue);
      expect(c.draft!.dirty, isTrue);
      expect(c.draft!.node(ops)!.name, '다항식의 계산');
      expect(b.unitName(ops), '다항식의 연산', reason: '더 새 저장본을 덮어쓰지 않는다');

      await c.loadCourse(id);
      expect(c.draft!.dirty, isFalse, reason: '최신 저장본을 불러오면 편집은 버려진다');
      expect(c.saveError(id), isNull);
      c.rename(ops, '다항식의 계산');
      expect(await c.save(), isTrue);
      expect(b.unitName(ops), '다항식의 계산');
    });

    test('빈 이름은 보내지 않고 막는다', () async {
      final (b, id, c) = await _loaded();
      c.rename(b.unitId(id, '곱셈'), '  ');
      expect(await c.save(), isFalse);
      expect(c.saveError(id)?.code, 'invalid');
      expect(b.writes, 0);
    });

    test('저장하는 동안에는 편집을 받지 않는다', () async {
      final (b, id, c) = await _loaded();
      final ops = b.unitId(id, '다항식의 연산');
      c.rename(ops, 'A');
      final gate = b.holdSave = Completer<void>();
      final saving = c.save();
      expect(c.busyCourseId, id);
      c.rename(ops, 'B');
      gate.complete();
      expect(await saving, isTrue);
      expect(b.unitName(ops), 'A');
      expect(c.draft!.node(ops)!.name, 'A');
    });

    test('보관은 저장 때 하고, 되살리면 같은 id로 끝에 돌아온다. 저장 안 한 편집이 있으면 막는다', () async {
      final (b, id, c) = await _loaded();
      final ops = b.unitId(id, '다항식의 연산');
      final add = b.unitId(id, '덧셈과 뺄셈');
      c.removeUnit(ops);
      expect(b.isArchived(ops), isFalse, reason: '빼기만 하고 저장 전에는 보관하지 않는다');
      expect(await c.save(), isTrue);
      expect(b.lastArchive?.toSet(), {ops, add, b.unitId(id, '곱셈')});
      expect(b.isArchived(add), isTrue);
      final archived = c.draft!.base.archived;
      expect(archived.single.id, ops);
      expect(archived.single.count, 3);
      expect(archived.single.path, ['다항식']);

      c.rename(b.unitId(id, '항등식'), '항등식의 뜻');
      expect(await c.restoreUnit(ops), contains('저장하지 않은 편집'));
      expect(b.isArchived(ops), isTrue);
      c.discard();

      expect(await c.restoreUnit(ops), isNull);
      expect(b.isArchived(add), isFalse);
      final d = c.draft!;
      expect(d.selectedId, ops);
      expect(d.childrenOf(b.unitId(id, '다항식')).last, ops);
      expect(d.childrenOf(ops), [add, b.unitId(id, '곱셈')]);
      expect(d.base.archived, isEmpty);
    });

    test('과정마다 편집본이 따로 남는다', () async {
      final (b, id, c) = await _loaded();
      final other = c.activeCourses[1].id;
      c.rename(b.unitId(id, '곱셈'), '곱셈 공식');
      c.selectCourse(other);
      await Future<void>.delayed(Duration.zero);
      expect(c.draft!.course.id, other);
      expect(c.anyDirty, isTrue);
      c.selectCourse(id);
      expect(c.draft!.node(b.unitId(id, '곱셈'))!.name, '곱셈 공식');
    });
  });

  group('과정', () {
    test('추가·순서·보관·되살리기', () async {
      final (b, id, c) = await _loaded();
      final other = c.activeCourses[1].id;

      expect(await c.createCourse(name: '대수', schoolLevel: '고', curriculumCode: 'rev_2022'), isNull);
      expect(c.selectedCourse?.name, '대수');
      expect(c.selectedCourse?.seeded, isFalse);
      expect(c.activeCourses.map((x) => x.name), ['공통수학1', '공통수학2', '대수']);

      expect(await c.moveCourse(other, -1), isNull);
      expect(c.activeCourses.map((x) => x.name), ['공통수학2', '공통수학1', '대수']);
      expect(c.activeCourses.map((x) => x.sortOrder), [0, 1, 2]);

      c.selectCourse(id);
      c.rename(b.unitId(id, '곱셈'), '곱셈 공식');
      expect(await c.archiveCourse(id), contains('저장하지 않은 편집'));
      c.discard();
      expect(await c.archiveCourse(id), isNull);
      expect(c.activeCourses.map((x) => x.name), ['공통수학2', '대수']);
      expect(c.activeCourses.map((x) => x.sortOrder), [0, 1]);
      expect(c.archivedCourses.single.id, id);
      expect(c.selectedCourseId, isNot(id));

      expect(await c.restoreCourse(id), isNull);
      expect(c.activeCourses.last.id, id);
      expect(c.selectedCourseId, id);
      await Future<void>.delayed(Duration.zero);
      expect(c.draft!.node(b.unitId(id, '곱셈'))!.name, '곱셈', reason: '같은 단원 그대로 돌아온다');
    });

    test('다른 곳에서 목록이 바뀌었으면 순서를 바꾸지 않는다', () async {
      final (b, _, c) = await _loaded();
      b.addCourse('기하');
      final first = c.activeCourses.first.id;
      expect(await c.moveCourse(first, 1), contains('과정 목록이 바뀌었습니다'));
      expect((await b.list()).first.id, first);
    });
  });

  group('개념 배치', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('과정을 읽으면 단원별 개념을 읽고, 넣기·순서·옮기기·빼기는 바로 저장된다', () async {
      final (b, id) = _seed();
      final add = b.unitId(id, '덧셈과 뺄셈');
      final mul = b.unitId(id, '곱셈');
      final k1 = b.addConcept('다항식의 덧셈');
      final k2 = b.addConcept('다항식의 뺄셈');
      final k3 = b.addConcept('곱셈 공식');
      b.place(add, k1, origin: 'ai', note: '교재 1단원');
      final c = _controller(b);
      await c.loadList();
      await flush();

      expect(c.placementsIn(id, add).map((p) => p.name), ['다항식의 덧셈']);
      expect(c.placementsIn(id, add).single.byThink, isTrue);
      expect(c.placementCount(id, add), 1);
      expect(c.overview?.concepts, 3);
      expect(c.overview?.placed, 1);
      expect(b.writes, 0, reason: '읽기만 한다');

      expect(await c.addPlacements(add, [k2, k3]), isNull);
      expect(b.namesIn(add), ['다항식의 덧셈', '다항식의 뺄셈', '곱셈 공식']);
      expect(c.placementsIn(id, add).map((p) => p.name), ['다항식의 덧셈', '다항식의 뺄셈', '곱셈 공식']);
      await flush();
      expect(c.overview?.placed, 3);

      expect(await c.addPlacements(add, [k1]), contains('이미 그 단원'));
      expect(b.namesIn(add).length, 3);

      final last = c.placementsIn(id, add).last.id;
      expect(await c.shiftPlacement(add, last, -1), isNull);
      expect(b.namesIn(add), ['다항식의 덧셈', '곱셈 공식', '다항식의 뺄셈']);

      expect(await c.movePlacement(last, mul), isNull);
      expect(b.namesIn(add), ['다항식의 덧셈', '다항식의 뺄셈']);
      expect(c.placementsIn(id, mul).single.name, '곱셈 공식');
      expect(c.placementsIn(id, mul).single.byThink, isFalse, reason: '사용자가 옮기면 사용자 배치가 된다');

      final first = c.placementsIn(id, add).first.id;
      expect(await c.removePlacement(first), isNull);
      expect(b.namesIn(add), ['다항식의 뺄셈']);
      expect(c.placementCount(id, add), 1);
    });

    test('그사이 단원 목록이 바뀌었으면 순서를 바꾸지 않고 다시 읽는다', () async {
      final (b, id) = _seed();
      final add = b.unitId(id, '덧셈과 뺄셈');
      final p1 = b.place(add, b.addConcept('가'));
      b.place(add, b.addConcept('나'));
      final c = _controller(b);
      await c.loadList();
      await flush();
      b.place(add, b.addConcept('다'));

      expect(await c.shiftPlacement(add, p1, 1), contains('개념 목록이 바뀌었습니다'));
      expect(b.namesIn(add), ['가', '나', '다']);
      await flush();
      expect(c.placementsIn(id, add).map((p) => p.name), ['가', '나', '다']);
    });

    test('배치를 읽지 못하면 오류만 남기고 예전 목록을 최신처럼 보이지 않는다', () async {
      final (b, id) = _seed();
      final add = b.unitId(id, '덧셈과 뺄셈');
      b.place(add, b.addConcept('가'));
      final c = _controller(b);
      await c.loadList();
      await flush();
      expect(c.placementCount(id, add), 1);

      b.failPlacements = CourseMapException('not_ready', 'DB에 개념 배치 기능이 아직 없습니다.');
      await c.reloadPlacements();
      expect(c.placementsOf(id), isNull);
      expect(c.placementCount(id, add), 0);
      expect(c.placementError(id)?.code, 'not_ready');

      b.failPlacements = null;
      await c.reloadPlacements();
      expect(c.placementError(id), isNull);
      expect(c.placementCount(id, add), 1);
    });

    test('화면 밖에서 바뀌면 저장 안 한 편집이 없는 과정만 새로 읽고, 편집 중인 과정은 배치만 다시 읽는다', () async {
      final (b, id, c) = await _loaded();
      await flush();
      final other = c.activeCourses[1].id;
      c.selectCourse(other);
      await flush();
      final ops = b.unitId(id, '다항식의 연산');
      final add = b.unitId(id, '덧셈과 뺄셈');
      final shape = b.unitId(other, '도형의 방정식');

      b.renameElsewhere(ops, '다항식의 계산');
      b.place(add, b.addConcept('가'));
      await c.refreshAfterExternalChange();
      expect(c.isDirty(id), isFalse);
      c.selectCourse(id);
      expect(c.draft!.node(ops)!.name, '다항식의 계산');
      expect(c.draft!.course.version, 2);
      await flush();
      expect(c.placementCount(id, add), 1);

      c.rename(b.unitId(id, '곱셈'), '곱셈 공식');
      b.renameElsewhere(ops, '다항식의 셈');
      b.place(shape, b.addConcept('나'));
      b.place(add, b.addConcept('다'));
      await c.refreshAfterExternalChange(courseId: id);
      expect(c.draft!.node(b.unitId(id, '곱셈'))!.name, '곱셈 공식', reason: '저장 안 한 편집은 버리지 않는다');
      expect(c.draft!.node(ops)!.name, '다항식의 계산');
      expect(c.placementCount(id, add), 2, reason: '배치는 다시 읽는다');
      expect(c.placementCount(other, shape), 0, reason: '말한 과정만 다시 읽는다');
      expect(await c.save(), isFalse, reason: '판이 달라 덮어쓰지 않는다');
      expect(b.unitName(ops), '다항식의 셈');
    });

    test('대·중단원 합계는 아래 단원까지 같은 개념을 한 번만 세고, 개념이 놓인 맨 아래 단원 수를 센다', () async {
      final (b, id) = _seed();
      final top = b.unitId(id, '다항식');
      final ops = b.unitId(id, '다항식의 연산');
      final add = b.unitId(id, '덧셈과 뺄셈');
      final mul = b.unitId(id, '곱셈');
      final k1 = b.addConcept('가');
      b.place(add, k1);
      b.place(add, b.addConcept('나'));
      b.place(mul, k1);
      b.place(ops, b.addConcept('다'));
      final c = _controller(b);
      await c.loadList();
      await flush();

      final t = courseUnitTallies(c.draft!, c.placementsOf(id)!);
      expect((t[ops]!.concepts, t[ops]!.filledLeaves, t[ops]!.leaves), (3, 2, 2), reason: '중단원에 바로 놓인 개념도 센다');
      expect((t[top]!.concepts, t[top]!.filledLeaves, t[top]!.leaves), (3, 2, 4));
      final other = b.unitId(id, '방정식과 부등식');
      expect((t[other]!.concepts, t[other]!.filledLeaves, t[other]!.leaves), (0, 0, 1));
      expect((t[add]!.concepts, t[add]!.leaves), (2, 1));
    });

    test('개념 줄 펼치기는 화면 상태라 저장할 변경으로 세지 않고, 모두 펼치면 위 단원도 펼친다', () async {
      final (b, id) = _seed();
      final top = b.unitId(id, '다항식');
      final ops = b.unitId(id, '다항식의 연산');
      final add = b.unitId(id, '덧셈과 뺄셈');
      b.place(add, b.addConcept('가'));
      final c = _controller(b);
      await c.loadList();
      await flush();

      final mul = b.unitId(id, '곱셈');
      b.place(mul, b.addConcept('나'));
      await c.reloadPlacements();
      c.setAllExpanded(false);
      c.toggleConcepts(id, add);
      expect(c.conceptsOpen(id, add), isTrue);
      expect(c.allConceptsOpen(id), isFalse, reason: '곱셈은 아직 접혀 있다');
      c.toggleConcepts(id, add);
      expect(c.conceptsOpen(id, add), isFalse);

      c.setAllConceptsOpen(id, true);
      expect(c.conceptsOpen(id, add), isTrue);
      expect(c.allConceptsOpen(id), isTrue);
      expect(c.conceptsOpen(id, ops), isFalse, reason: '개념이 없는 단원은 펼치지 않는다');
      expect(c.draft!.expanded.containsAll([top, ops]), isTrue);
      expect(c.isDirty(id), isFalse);
      expect(b.writes, 0);

      c.setAllConceptsOpen(id, false);
      expect(c.conceptsOpen(id, add) || c.conceptsOpen(id, mul), isFalse);
    });

    test('최근 변경은 읽기만 하고, 잘못된 종류는 알려 준다', () async {
      final (b, _) = _seed();
      b.changes.addAll([
        CourseChange.fromJson({
          'key': 'p:2', 'at': '2026-10-24T03:00:00+00:00', 'kind': 'placement', 'action': 'move',
          'concept_id': 'k1', 'concept_name': '가', 'path': ['다항식', '곱셈'], 'from_path': ['다항식', '덧셈'],
          'origin': 'ai', 'action_id': 'a1', 'note': '교재 순서',
        }),
        CourseChange.fromJson({
          'key': 'c:1', 'at': '2026-10-24T02:00:00+00:00', 'kind': 'content', 'concept_id': 'k2',
          'concept_name': '나', 'before_name': '나전', 'after_name': '나', 'renamed': true, 'via': 'direct',
        }),
      ]);
      final c = _controller(b);
      final all = await c.recentChanges();
      expect(all.items.map((x) => x.key), ['p:2', 'c:1']);
      expect(all.items.first.fromPath, ['다항식', '덧셈']);
      expect(all.items.first.byThink, isTrue);
      expect(all.items.first.time, DateTime.utc(2026, 10, 24, 3).toLocal());
      final placed = await c.recentChanges(kinds: [kCourseChangePlacement]);
      expect(placed.items.single.kind, kCourseChangePlacement);
      final older = await c.recentChanges(olderThan: all.items.first);
      expect(older.items.single.renamed, isTrue);

      await expectLater(
        c.recentChanges(kinds: ['other']),
        throwsA(isA<CourseMapException>().having((e) => e.message, 'message', '알 수 없는 변경 종류입니다.')),
      );
      expect(b.writes, 0);
    });
  });
}
