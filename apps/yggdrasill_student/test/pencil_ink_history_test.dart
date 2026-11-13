import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/widgets/pencil_ink_history.dart';

void main() {
  test('되돌리기는 마지막 획을 빼고 다시 실행하면 그 획이 돌아온다', () {
    final history = PencilInkHistory();
    history.beginStroke(const Offset(1, 1), 0, 1);
    history.beginStroke(const Offset(2, 2), 10, 1);
    history.beginStroke(const Offset(3, 3), 20, 1);

    expect(history.undo(strokeOpen: false), isTrue);
    expect(history.strokes.map((stroke) => stroke.first.dx), [1, 2]);
    expect(history.redo(strokeOpen: false), isTrue);
    expect(history.strokes.map((stroke) => stroke.first.dx), [1, 2, 3]);
    expect(history.redoStrokes, isEmpty);
  });

  test('진행 중인 획은 남기고 그 앞의 끝난 획을 되돌린다', () {
    final history = PencilInkHistory();
    history.beginStroke(const Offset(1, 1), 0, 1);
    history.beginStroke(const Offset(9, 9), 10, 1);

    expect(history.undo(strokeOpen: true), isTrue);
    expect(history.strokes.single.first.dx, 9);
    expect(history.redo(strokeOpen: true), isTrue);
    expect(history.strokes.map((stroke) => stroke.first.dx), [1, 9]);
  });

  test('새 획이 확정되면 되돌렸던 획은 버려진다', () {
    final history = PencilInkHistory();
    history.beginStroke(const Offset(1, 1), 0, 1);
    history.undo(strokeOpen: false);
    history.beginStroke(const Offset(4, 4), 30, 1);
    history.discardRedo();

    expect(history.redoStrokes, isEmpty);
    expect(history.redo(strokeOpen: false), isFalse);
    expect(history.strokes.single.first.dx, 4);
  });

  test('등록 응답 전에 시스템 되돌리기가 오면 그 등록은 개수에 넣지 않는다', () {
    final ledger = ApplePencilUndoLedger();
    ledger.beginPush();
    ledger.notePopped();
    expect(ledger.finishPush(registered: true, epoch: ledger.epoch), isFalse);
    expect(ledger.levels, 0);

    ledger.beginPush();
    ledger.buttonUndoWhilePushPending();
    expect(ledger.finishPush(registered: true, epoch: ledger.epoch), isTrue);
    expect(ledger.levels, 0);
  });

  test('기존 글자 위를 좌우로 문지르면 그 글자 묶음을 지우고 한 번에 복구한다', () {
    final history = PencilInkHistory();

    // 왼쪽 숫자 '1' (x=20)
    history.beginStroke(const Offset(20, 30), 0, 1);
    history.extendStroke(const Offset(20, 75), 20, 1);
    expect(history.commitOpenStroke(), PencilCommitOutcome.added);

    // 오른쪽 '+' 기호 두 획 (가로획 + 세로획, x=60..90, y=35..65)
    history.beginStroke(const Offset(60, 50), 40, 1);
    history.extendStroke(const Offset(90, 50), 60, 1);
    expect(history.commitOpenStroke(), PencilCommitOutcome.added);

    history.beginStroke(const Offset(75, 35), 80, 1);
    history.extendStroke(const Offset(75, 65), 100, 1);
    expect(history.commitOpenStroke(), PencilCommitOutcome.added);

    expect(history.strokes.length, 3);

    // 오른쪽 '+' 위를 펜을 떼지 않고 좌우로 문지른다 (오→왼→오→왼).
    history.beginStroke(const Offset(56, 46), 120, 1);
    history.extendStroke(const Offset(94, 48), 140, 1);
    history.extendStroke(const Offset(56, 51), 160, 1);
    history.extendStroke(const Offset(94, 54), 180, 1);
    history.extendStroke(const Offset(56, 56), 200, 1);

    expect(history.commitOpenStroke(), PencilCommitOutcome.erased);
    // 왼쪽 '1'만 남고 '+'의 두 획과 문지른 획은 모두 사라진다.
    expect(history.strokes.length, 1);
    expect(history.strokes.single.first.dx, 20);

    // 되돌리기 한 번이면 지워졌던 '+'의 두 획이 한꺼번에 돌아온다.
    expect(history.undo(strokeOpen: false), isTrue);
    expect(history.strokes.length, 3);

    // 다시 실행하면 다시 '+' 묶음이 지워진다.
    expect(history.redo(strokeOpen: false), isTrue);
    expect(history.strokes.length, 1);
  });

  test('빈 공간에 쓴 z나 옆에 쓴 3은 문지르기 지우개로 오인하지 않는다', () {
    final history = PencilInkHistory();

    // 왼쪽 숫자 '1' (x=20)
    history.beginStroke(const Offset(20, 30), 0, 1);
    history.extendStroke(const Offset(20, 75), 20, 1);
    expect(history.commitOpenStroke(), PencilCommitOutcome.added);

    // 바로 옆(x=27..55)에 위에서 아래로 내려오는 '3' 모양 필기
    history.beginStroke(const Offset(28, 30), 40, 1);
    history.extendStroke(const Offset(54, 38), 60, 1);
    history.extendStroke(const Offset(32, 52), 80, 1);
    history.extendStroke(const Offset(55, 64), 100, 1);
    history.extendStroke(const Offset(27, 76), 120, 1);

    expect(history.commitOpenStroke(), PencilCommitOutcome.added);
    expect(history.strokes.length, 2);
  });

  test('위에서 아래로 3~4번 왕복하거나 약간 기울어진 문지르기도 글자를 지운다', () {
    // 3회 왕복(→ ← →)이 위에서 아래로 내려오며 '5' 크기의 글자를 덮는 경우
    final threePass = PencilInkHistory();
    threePass.beginStroke(const Offset(50, 30), 0, 1);
    threePass.extendStroke(const Offset(50, 62), 20, 1);
    expect(threePass.commitOpenStroke(), PencilCommitOutcome.added);

    threePass.beginStroke(const Offset(34, 34), 40, 1);
    threePass.extendStroke(const Offset(66, 39), 60, 1);
    threePass.extendStroke(const Offset(34, 48), 80, 1);
    threePass.extendStroke(const Offset(66, 58), 100, 1);
    expect(threePass.commitOpenStroke(), PencilCommitOutcome.erased);
    expect(threePass.strokes, isEmpty);

    // 4회 왕복(→ ← → ←)이 정사각형에 가까운 세로 높이로 지그재그 지우는 경우
    final fourPass = PencilInkHistory();
    fourPass.beginStroke(const Offset(50, 30), 0, 1);
    fourPass.extendStroke(const Offset(50, 64), 20, 1);
    expect(fourPass.commitOpenStroke(), PencilCommitOutcome.added);

    fourPass.beginStroke(const Offset(36, 32), 40, 1);
    fourPass.extendStroke(const Offset(64, 36), 60, 1);
    fourPass.extendStroke(const Offset(36, 44), 80, 1);
    fourPass.extendStroke(const Offset(64, 52), 100, 1);
    fourPass.extendStroke(const Offset(36, 62), 120, 1);
    expect(fourPass.commitOpenStroke(), PencilCommitOutcome.erased);
    expect(fourPass.strokes, isEmpty);

    // 얇은 숫자 '1' 위를 좁게 문지르는 경우
    final narrow = PencilInkHistory();
    narrow.beginStroke(const Offset(40, 40), 0, 1);
    narrow.extendStroke(const Offset(40, 68), 20, 1);
    expect(narrow.commitOpenStroke(), PencilCommitOutcome.added);

    narrow.beginStroke(const Offset(33, 48), 40, 1);
    narrow.extendStroke(const Offset(47, 50), 60, 1);
    narrow.extendStroke(const Offset(33, 53), 80, 1);
    narrow.extendStroke(const Offset(47, 56), 100, 1);
    expect(narrow.commitOpenStroke(), PencilCommitOutcome.erased);
    expect(narrow.strokes, isEmpty);
  });
}
