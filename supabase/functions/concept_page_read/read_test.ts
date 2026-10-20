import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import {
  buildConceptPagePrompt,
  CONCEPT_PAGE_SCHEMA,
  parseConceptPage,
  readConceptPageBody,
} from './prompt.ts';
import { readConceptPage } from './read.ts';

const input = {
  bookName: '개념+유형',
  gradeLabel: '1-1',
  unitPath: ['수와 연산', '소인수분해', '소인수분해'],
  rawPage: 8,
  displayPage: 8,
  masks: [{ label: 'M1', bbox_1k: [600, 50, 950, 480], problem_number: '0001' }],
};

function assertStrictObjects(schema: unknown, path = '$'): void {
  if (!schema || typeof schema !== 'object') return;
  const s = schema as Record<string, unknown>;
  if (s.type === 'object') {
    assertEquals(s.additionalProperties, false, `${path}: additionalProperties`);
    const keys = Object.keys(s.properties as Record<string, unknown>).sort();
    assertEquals([...(s.required as string[])].sort(), keys, `${path}: required`);
    for (const [k, v] of Object.entries(s.properties as Record<string, unknown>)) assertStrictObjects(v, `${path}.${k}`);
  }
  if (s.type === 'array') assertStrictObjects(s.items, `${path}[]`);
  assert(!Array.isArray(s.type), `${path}: null 형식은 Gemini 쪽과 같이 쓰지 않는다`);
}

Deno.test('출력 형식은 strict 조건(모든 키 필수, 추가 키 없음)을 지킨다', () => {
  assertStrictObjects(CONCEPT_PAGE_SCHEMA);
});

Deno.test('사용자 지시에 단원·쪽·가린 문항 영역이 들어간다', () => {
  const p = buildConceptPagePrompt(input);
  assert(p.userText.includes('수와 연산 > 소인수분해 > 소인수분해'));
  assert(p.userText.includes('PDF 8쪽'));
  assert(p.userText.includes('M1 (문항 0001): [600, 50, 950, 480]'));
  const none = buildConceptPagePrompt({ ...input, masks: [], displayPage: 10 });
  assert(none.userText.includes('교재 표시 10쪽'));
  assert(none.userText.includes('회색 상자가 없습니다'));
});

Deno.test('모델 출력 정리: 모르는 종류는 other, 잘못된 영역은 null, 빈 블록은 버린다', () => {
  const page = parseConceptPage(
    '```json\n' +
      JSON.stringify({
        page_kind: 'mixed',
        blocks: [
          { kind: 'concept_box', title: '개념 1', text: '소수', bbox_1k: [10, 20, 300, 980], figure_description: '', continues_from_prev_page: false, continues_to_next_page: false, uncertain: false },
          { kind: 'weird', title: '', text: '본문', bbox_1k: [300, 0, 200, 100] },
          { kind: 'explanation', title: '', text: '   ', bbox_1k: [0, 0, 10, 10] },
          { kind: 'figure', text: '', figure_description: '수형도', bbox_1k: [1, 2, 1200, 4] },
        ],
        notes: ' 없음 ',
      }) +
      '\n```',
  );
  assert(page);
  assertEquals(page.page_kind, 'mixed');
  assertEquals(page.blocks.length, 3);
  assertEquals(page.blocks[0].bbox_1k, [10, 20, 300, 980]);
  assertEquals(page.blocks[1].kind, 'other');
  assertEquals(page.blocks[1].bbox_1k, null);
  assertEquals(page.blocks[2].bbox_1k, [1, 2, 1000, 4]);
  assertEquals(page.notes, '없음');
  assertEquals(parseConceptPage('이건 JSON이 아님'), null);
});

Deno.test('요청 본문 검사: 이미지·쪽·가림 영역이 맞지 않으면 거절한다', () => {
  const ok = readConceptPageBody({
    image_base64: 'aGk=',
    raw_page: 8,
    book_name: '개념+유형',
    grade_label: '1-1',
    unit_path: ['수와 연산', ' ', '소인수분해'],
    masks: [{ label: 'M1', bbox_1k: [1, 2, 3, 4] }],
  });
  assert(ok.ok);
  if (ok.ok) {
    assertEquals(ok.mimeType, 'image/png');
    assertEquals(ok.input.unitPath, ['수와 연산', '소인수분해']);
  }
  assertEquals(readConceptPageBody({ raw_page: 8 }), { ok: false, error: 'image_required' });
  assertEquals(readConceptPageBody({ image_base64: 'a', raw_page: 8.5 }), { ok: false, error: 'invalid_page' });
  assertEquals(readConceptPageBody({ image_base64: 'a', raw_page: 8, mime_type: 'image/gif' }), { ok: false, error: 'unsupported_mime' });
  assertEquals(
    readConceptPageBody({ image_base64: 'a', raw_page: 8, masks: [{ label: 'M1', bbox_1k: [5, 5, 1, 1] }] }),
    { ok: false, error: 'invalid_masks' },
  );
});

Deno.test('한 쪽 읽기: 이미지·형식을 붙여 부르고 결과를 정리해 돌려준다', async () => {
  const provider = new FakeAiProvider();
  const out = await readConceptPage(provider, {
    model: 'gpt-test',
    reasoningEffort: 'low',
    input,
    imageBase64: 'aGk=',
    mimeType: 'image/png',
  });
  assertEquals(out.error, null);
  assert(out.page);
  const req = provider.requests[0];
  assertEquals(req.jsonSchema?.name, 'concept_page');
  assertEquals(req.reasoningEffort, 'low');
  const msg = req.input[0];
  assert(msg.kind === 'message');
  const image = msg.parts.find((p) => p.type === 'image');
  assert(image && image.type === 'image' && image.url.startsWith('data:image/png;base64,'));
});

Deno.test('한 쪽 읽기: 공급자 오류와 형식 밖 출력은 오류로 돌려준다', async () => {
  const failed = await readConceptPage(new FakeAiProvider([{ error: 'boom' }]), {
    model: 'gpt-test',
    reasoningEffort: 'low',
    input,
    imageBase64: 'aGk=',
    mimeType: 'image/png',
  });
  assertEquals(failed.page, null);
  assert(failed.error);
  const invalid = await readConceptPage(new FakeAiProvider([{ text: '그냥 문장' }]), {
    model: 'gpt-test',
    reasoningEffort: 'low',
    input,
    imageBase64: 'aGk=',
    mimeType: 'image/png',
  });
  assertEquals(invalid.error, 'invalid_output');
  assert(invalid.result);
});
