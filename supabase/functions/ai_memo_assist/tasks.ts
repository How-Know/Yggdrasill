// 학습앱 메모 보조 작업의 프롬프트와 출력 검증. 모델 출력은 형식을 확인한 값만 돌려준다.

export const MEMO_PROMPT_VERSION = 'memo-assist-2026-09-28';

export type MemoTask = 'summarize' | 'summarize_sentence' | 'extract_datetime' | 'extract_phone' | 'extract_name';

export const MEMO_TASKS: ReadonlySet<string> = new Set([
  'summarize',
  'summarize_sentence',
  'extract_datetime',
  'extract_phone',
  'extract_name',
]);

export interface MemoPrompt {
  instructions: string;
  userText: string;
  maxOutputTokens: number;
}

const WEEKDAYS = ['일', '월', '화', '수', '목', '금', '토'];

export function kstToday(now = new Date()): string {
  const kst = new Date(now.getTime() + 9 * 3600 * 1000);
  return `${kst.toISOString().slice(0, 10)} (${WEEKDAYS[kst.getUTCDay()]}요일)`;
}

export function memoPrompt(task: MemoTask, text: string, opts: { maxChars: number; now?: Date }): MemoPrompt {
  const n = opts.maxChars;
  switch (task) {
    case 'summarize':
      return {
        instructions: `너는 텍스트를 한 줄 키워드로 요약하는 비서다. 한국어로 명사/명사구 중심의 한 줄만 출력하라. 문장부호(.,!?)와 불필요한 조사/수식어를 제거하고, 줄바꿈 없이 ${n}자 이내로 핵심 키워드만 제공하라.`,
        userText: `다음 텍스트에서 핵심 키워드를 한 줄(최대 ${n}자)로 요약해줘. 문장은 금지, 쉼표 없이 간결한 명사구로:\n${text}`,
        maxOutputTokens: 200,
      };
    case 'summarize_sentence':
      return {
        instructions: `너는 텍스트를 한 문장으로 간결하게 요약하는 비서다. 한국어로 한 문장만 출력하고, 줄바꿈 없이 ${n}자 이내로 핵심만 담아라.`,
        userText: `다음 텍스트를 한 문장(최대 ${n}자)으로 간결하게 요약해줘. 불필요한 수식어/군더더기 금지:\n${text}`,
        maxOutputTokens: 200,
      };
    case 'extract_datetime':
      return {
        instructions: `사용자 문장에서 일정 날짜/시간을 찾아 한국시간 기준 ISO 8601(yyyy-MM-ddTHH:mm) 문자열로만 출력. 없으면 null만 출력. 오늘은 ${kstToday(opts.now)}이다.`,
        userText: text,
        maxOutputTokens: 40,
      };
    case 'extract_phone':
      return {
        instructions: '사용자 문장에서 한국 휴대전화 하나를 010-1234-5678 형식으로만 출력. 없으면 null.',
        userText: text,
        maxOutputTokens: 30,
      };
    case 'extract_name':
      return {
        instructions: '사용자 문장에서 한국인의 고유명사 이름(한글 2~4자)만 출력. 없으면 null. 호칭(학생, 님, 보호자 등) 제외.',
        userText: text,
        maxOutputTokens: 20,
      };
  }
}

function oneLine(raw: string): string {
  return raw.replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
}

/** 형식이 맞지 않으면 null. 앱은 null이면 기존 정규식 처리로 돌아간다. */
export function parseMemoOutput(task: MemoTask, raw: string): string | null {
  const out = oneLine(raw).replace(/^["'`]+|["'`]+$/g, '');
  if (!out || out.toLowerCase() === 'null') return null;
  switch (task) {
    case 'summarize':
    case 'summarize_sentence':
      return out;
    case 'extract_datetime': {
      const m = out.match(/(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/);
      if (!m) return null;
      const [, y, mo, d, h, mi] = m.map(Number);
      if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
      return `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}`;
    }
    case 'extract_phone': {
      const digits = out.replace(/\D/g, '');
      if (digits.length === 11 && digits.startsWith('01')) return `${digits.slice(0, 3)}-${digits.slice(3, 7)}-${digits.slice(7)}`;
      if (digits.length === 10 && digits.startsWith('01')) return `${digits.slice(0, 3)}-${digits.slice(3, 6)}-${digits.slice(6)}`;
      return null;
    }
    case 'extract_name':
      return /^[가-힣]{2,4}$/.test(out) ? out : null;
  }
}
