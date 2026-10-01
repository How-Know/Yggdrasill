import { assert, assertEquals } from 'jsr:@std/assert@1';
import { memoPrompt, parseMemoOutput } from './tasks.ts';

Deno.test('메모 출력은 형식이 맞을 때만 값을 돌려준다', () => {
  assertEquals(parseMemoOutput('extract_datetime', '2026-10-02T15:30'), '2026-10-02T15:30');
  assertEquals(parseMemoOutput('extract_datetime', '"2026-10-02 15:30"'), '2026-10-02T15:30');
  assertEquals(parseMemoOutput('extract_datetime', '2026-13-02T15:30'), null);
  assertEquals(parseMemoOutput('extract_datetime', 'null'), null);
  assertEquals(parseMemoOutput('extract_phone', '01012345678'), '010-1234-5678');
  assertEquals(parseMemoOutput('extract_phone', '없음'), null);
  assertEquals(parseMemoOutput('extract_name', '김하늘'), '김하늘');
  assertEquals(parseMemoOutput('extract_name', '김하늘 학생'), null);
  assertEquals(parseMemoOutput('summarize', '상담 일정\n변경'), '상담 일정 변경');
});

Deno.test('일정 추출 프롬프트에는 오늘 날짜가 들어간다', () => {
  const p = memoPrompt('extract_datetime', '다음 주 화요일 3시', { maxChars: 60, now: new Date('2026-09-28T03:00:00Z') });
  assert(p.instructions.includes('2026-09-28 (월요일)'));
});
