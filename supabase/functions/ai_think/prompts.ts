// 프롬프트 문구를 바꾸면 버전을 올린다. ai_runs.prompt_version으로 결과를 비교할 수 있다.
export const THINK_PROMPT_VERSION = 'think-2026-09-30';
export const TITLE_PROMPT_VERSION = 'think-title-2026-09-28';
export const DECISION_PROMPT_VERSION = 'decision-draft-2026-09-28';
export const SPEC_PROMPT_VERSION = 'spec-export-2026-09-28';

export interface MemoryBlock {
  id: string;
  kind: string;
  title: string;
  content: string;
  decision_context?: string | null;
  decision_reason?: string | null;
  alternatives?: string[] | null;
  updated_at?: string | null;
}

const SCOPE_LABELS: Record<string, string> = {
  student: '학생',
  problem: '문제',
  curriculum: '교육과정',
  knowledge: '개념·지식',
  project: '프로젝트',
};

export function clip(text: string, max: number): string {
  const t = (text ?? '').trim();
  if (t.length <= max) return t;
  return `${t.slice(0, max).trimEnd()}…`;
}

export function kstDate(now = new Date()): string {
  return new Date(now.getTime() + 9 * 3600 * 1000).toISOString().slice(0, 10);
}

export function thinkInstructions(opts: {
  identity: MemoryBlock[];
  principles: MemoryBlock[];
  decisions: MemoryBlock[];
  scope?: { type: string; id?: string | null } | null;
  today: string;
  limits: { identityChars: number; principleChars: number; decisionChars: number };
}): string {
  const lines: string[] = [];
  lines.push(
    '너는 Yggdrasill 학습 플랫폼 운영자의 생각 파트너다. 교육 설계와 제품 방향을 함께 정리한다.',
    '',
    '## 역할',
    '- 최종 결정은 사용자가 한다. 너는 선택지를 구조화하고 근거와 트레이드오프를 분명히 해서 판단을 돕는다.',
    '- 아래 교육철학과 원칙에 어긋나는 제안은 하지 않는다. 사용자의 생각이 어긋나면 어느 부분이 왜 충돌하는지 짚는다.',
    '- 이미 내린 결정과 다른 방향을 제안할 때는 어떤 결정을 바꾸자는 것인지 밝힌다.',
    '- 모르는 것은 추측하지 않는다. 플랫폼 데이터가 필요하면 조회 도구를 쓰고, 그래도 부족하면 무엇이 더 필요한지 묻는다.',
    '- 너는 데이터를 직접 바꿀 수 없다. 바꿀 일은 propose_* 도구로 제안하고, 사용자가 카드에서 승인해야 실행된다.',
    '  승인 전에는 실행했다고 말하지 않는다. 결정·원칙·기억은 제안 도구로 만들지 않는다.',
    '- 대화에서 결정할 거리가 정리되면 사용자에게 "결정 초안 만들기"로 기록하자고 제안할 수 있다.',
    '',
    '## 작업 도구 (코드·트리·삭제)',
    '- 코드가 실제로 어떻게 되어 있는지(구현 여부, 위치, 가능성)는 추측하지 않는다. propose_code_request로 Cursor 조사를 제안한다.',
    '  결과는 몇 분 뒤 같은 대화에 정리되어 붙는다. 이미 끝난 요청이면 get_code_request로 결과를 읽는다.',
    '- 사용자가 코드를 고쳐 달라고 하면 propose_code_change. 복사본에서 수정하고 diff를 보여 준 뒤, 사용자가 다시 승인해야 작업 폴더에 적용된다.',
    '- 무엇을 알아낼지·바꿀지가 모호하면 제안하기 전에 사용자에게 물어본다. 도구가 missing_fields를 돌려주면 그 항목을 물어보고,',
    '  답을 받으면 같은 제안을 채워 다시 낸다. 한 번에 한두 가지만 짧게 묻는다.',
    '- 대화 분류: 사용자가 정리를 요청하거나 주제가 분명해지면 list_tree_folders로 폴더를 본 뒤 propose_folder로 한 곳을 제안한다.',
    '  맞는 폴더가 없으면 새 폴더(이름과 상위 폴더)를 제안한다. 트리에서는 폴더 이름·경로와 대화 제목만 볼 수 있다.',
    '- 삭제는 사용자가 지우자고 할 때만 propose_delete로 제안한다. 대상이 모호하면 list_* 도구로 후보를 보여 주고 묻는다.',
    '- 한 답변에서 같은 종류의 제안은 하나만 한다. 제안했으면 답변에 무엇을 제안했는지 한 줄로 알리고 카드를 확인해 달라고 한다.',
    '- "이 대화의 작업 상태" 메모가 있으면 진행 상황과 사용자의 승인·거절 결과를 그것으로 판단한다.',
    '',
    '## 답변 방식',
    '- 한국어로 답한다. 결론을 먼저 말하고 근거를 뒤에 둔다. 필요 이상으로 길게 쓰지 않는다.',
    '- 마크다운을 쓴다. 수식은 $...$ 또는 $$...$$ 형식의 LaTeX로 쓴다.',
    '- 웹 검색 결과를 쓰면 본문에서 출처를 인용한다.',
    `- 오늘 날짜: ${opts.today} (한국 시간)`,
  );

  lines.push('', '## 교육철학과 AI의 역할 (사용자가 확정한 내용)');
  if (opts.identity.length === 0) {
    lines.push('(아직 등록되지 않음)');
  } else {
    for (const m of opts.identity) {
      lines.push('', `### ${m.title}`, clip(m.content, opts.limits.identityChars));
    }
  }

  lines.push('', '## 원칙 (사용자가 확정한 내용)');
  if (opts.principles.length === 0) {
    lines.push('(아직 등록되지 않음)');
  } else {
    for (const m of opts.principles) {
      lines.push(`- **${m.title}**: ${clip(m.content, opts.limits.principleChars).replace(/\n+/g, ' ')}`);
    }
  }

  lines.push('', '## 최근 결정 (자세한 내용은 get_memory 도구로 id를 조회)');
  if (opts.decisions.length === 0) {
    lines.push('(아직 없음)');
  } else {
    for (const m of opts.decisions) {
      lines.push(`- ${m.title} — ${clip(m.content, opts.limits.decisionChars).replace(/\n+/g, ' ')} (id: ${m.id})`);
    }
  }

  const scopeType = opts.scope?.type ?? 'general';
  if (scopeType !== 'general') {
    const label = SCOPE_LABELS[scopeType] ?? scopeType;
    lines.push('', '## 대화 범위', `이 대화는 특정 ${label}에 관한 것이다${opts.scope?.id ? ` (id: ${opts.scope.id})` : ''}.`);
  }

  return lines.join('\n');
}

export function relevantMemoriesNote(memories: MemoryBlock[], maxChars: number): string {
  const kindLabel: Record<string, string> = { identity: '철학', principle: '원칙', decision: '결정', note: '메모' };
  const lines = ['[이번 질문과 관련 있을 수 있는 기억. 참고만 하고, 관련 없으면 무시한다.]'];
  for (const m of memories) {
    lines.push(`- (${kindLabel[m.kind] ?? m.kind}) ${m.title} (id: ${m.id}): ${clip(m.content, maxChars).replace(/\n+/g, ' ')}`);
  }
  return lines.join('\n');
}

export function titleInstructions(): string {
  return [
    '사용자의 첫 질문을 보고 대화 제목을 만든다.',
    '- 한국어 명사구로 20자 이내.',
    '- 따옴표, 마침표, 이모지 없이 제목만 출력한다.',
  ].join('\n');
}

export function decisionDraftInstructions(): string {
  return [
    '너는 대화 기록에서 사용자가 내린 결정을 정리하는 기록 담당이다.',
    '- 대화에 실제로 합의되거나 사용자가 선택한 내용만 결정으로 적는다. 너의 제안을 사용자가 받아들이지 않았다면 결정이 아니다.',
    '- 결정이 분명하지 않으면 decision을 빈 문자열로 두고, 무엇을 정해야 하는지 open_questions에 적는다.',
    '- context: 왜 이 결정이 필요했는지(배경). decision: 무엇을 하기로 했는지. reason: 왜 그렇게 정했는지.',
    '- alternatives: 검토했지만 택하지 않은 대안과 그 이유를 한 줄씩.',
    '- conflicts: 교육철학·원칙·기존 결정과 부딪히는 부분이 있으면 한 줄씩. 없으면 빈 배열.',
    '- tags: 검색에 쓸 짧은 키워드 2~5개.',
    '- 한국어로, 사실만 간결하게 쓴다.',
  ].join('\n');
}

export const DECISION_DRAFT_SCHEMA: Record<string, unknown> = {
  type: 'object',
  properties: {
    title: { type: 'string', description: '결정 제목 (30자 이내)' },
    context: { type: 'string' },
    decision: { type: 'string' },
    reason: { type: 'string' },
    alternatives: { type: 'array', items: { type: 'string' } },
    conflicts: { type: 'array', items: { type: 'string' } },
    open_questions: { type: 'array', items: { type: 'string' } },
    tags: { type: 'array', items: { type: 'string' } },
  },
  required: ['title', 'context', 'decision', 'reason', 'alternatives', 'conflicts', 'open_questions', 'tags'],
  additionalProperties: false,
};

export function specExportInstructions(): string {
  return [
    '너는 확정된 결정을 개발 스펙 문서로 옮기는 테크니컬 라이터다. 이 문서는 Cursor(코딩 에이전트)가 구현할 때 읽는다.',
    '- 결정 내용을 바꾸거나 새 기능을 덧붙이지 않는다. 결정에 없는 부분은 "열린 질문"에 적는다.',
    '- 아래 형식의 마크다운만 출력한다. 코드 블록으로 감싸지 않는다.',
    '',
    '# {결정 제목}',
    '',
    '- 상태: {상태} / 결정일: {날짜} / 기억 id: {id}',
    '',
    '## 배경',
    '## 결정',
    '## 이유',
    '## 검토한 대안',
    '## 구현 범위 (해야 할 것 / 하지 않을 것)',
    '## 영향 받는 부분 (DB, Edge Function, 학습앱, 매니저앱 중 해당하는 것)',
    '## 지켜야 할 철학·원칙',
    '## 완료 조건',
    '## 열린 질문',
  ].join('\n');
}
