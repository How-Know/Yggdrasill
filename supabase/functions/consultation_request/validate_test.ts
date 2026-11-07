import { assertEquals } from 'jsr:@std/assert@1';
import { cleanQuestion, cleanTime, normalizePhone } from './validate.ts';

Deno.test('휴대폰 번호는 국내 휴대폰만 받는다', () => {
  assertEquals(normalizePhone('010-1234-5678'), '01012345678');
  assertEquals(normalizePhone('+82 10 1234 5678'), '01012345678');
  assertEquals(normalizePhone('011-123-4567'), '0111234567');
  assertEquals(normalizePhone('02-123-4567'), null);
  assertEquals(normalizePhone('010-123-4567'), null);
});

Deno.test('상담 시간은 비어 있거나 너무 길면 받지 않는다', () => {
  assertEquals(cleanTime('  평일   저녁 7시  '), '평일 저녁 7시');
  assertEquals(cleanTime('   '), null);
  assertEquals(cleanTime('가'.repeat(81)), null);
});

Deno.test('궁금하신 점은 비워도 되고 500자를 넘기면 거절한다', () => {
  assertEquals(cleanQuestion(null), { ok: true, value: null });
  assertEquals(cleanQuestion('  '), { ok: true, value: null });
  assertEquals(cleanQuestion('수학 선행'), { ok: true, value: '수학 선행' });
  assertEquals(cleanQuestion('가'.repeat(501)), { ok: false });
});
