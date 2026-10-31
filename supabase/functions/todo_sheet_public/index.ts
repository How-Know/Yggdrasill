import { createAdminClient } from '../_shared/supabase.ts';

type Row = Record<string, unknown>;

const sliceColors = [
  '#2EAA68',
  '#4080EE',
  '#F4A330',
  '#9268E6',
  '#1EB6C4',
  '#EC5C62',
  '#AA8460',
  '#5C68E2',
];

function text(value: unknown): string {
  if (value == null) return '';
  return String(value).trim();
}

function esc(value: unknown): string {
  return text(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function rows(value: unknown): Row[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item) => item !== null && typeof item === 'object') as Row[];
}

function num(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function int(value: unknown): number {
  return Math.trunc(num(value) ?? 0);
}

function kstDate(value: unknown): string {
  const date = parsed(value);
  if (!date) return '';
  return new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    weekday: 'short',
  }).format(date);
}

function kstTime(value: unknown): string {
  const date = parsed(value);
  if (!date) return '';
  return new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).format(date);
}

function parsed(value: unknown): Date | null {
  const raw = text(value);
  if (!raw) return null;
  const date = new Date(raw);
  return Number.isNaN(date.getTime()) ? null : date;
}

function monthDay(value: unknown): string {
  const date = parsed(value);
  if (!date) return '-';
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Seoul',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date);
  const month = parts.find((part) => part.type === 'month')?.value ?? '';
  const day = parts.find((part) => part.type === 'day')?.value ?? '';
  return `${month}.${day}`;
}

function weekdayKo(value: unknown): string {
  const date = parsed(value);
  if (!date) return '';
  return new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    weekday: 'short',
  }).format(date).replace('요일', '');
}

function duration(ms: number): string {
  if (ms <= 0) return '';
  const minutes = Math.floor(ms / 60000);
  const hours = Math.floor(minutes / 60);
  const remain = minutes % 60;
  if (hours > 0) return `${hours}시간 ${remain}분`;
  return `${minutes}분`;
}

function pageText(value: unknown): string {
  const page = text(value);
  if (!page || page === '-') return '';
  return `p.${page}`;
}

function countText(value: unknown): string {
  const count = text(value);
  if (!count || count === '-') return '';
  return `${count}문항`;
}

function stayMs(payload: Row): number {
  const arrival = parsed(payload.arrival_time);
  const departure = parsed(payload.departure_time);
  if (!arrival || !departure || departure.getTime() <= arrival.getTime()) return 0;
  return departure.getTime() - arrival.getTime();
}

function pair(left: string, right = '', tone = ''): string {
  const meta = right
    ? `<span class="${tone}">${esc(right)}</span>`
    : '';
  return `<div class="pair"><p>${esc(left)}</p>${meta}</div>`;
}

function bar(previous: number, today: number, thin = false): string {
  const prev = Math.min(100, Math.max(0, previous));
  const add = Math.min(Math.max(0, 100 - prev), Math.max(0, today));
  return `<div class="bar${thin ? ' thin' : ''}" aria-hidden="true"><i class="add" style="width:${prev + add}%"></i><i class="prev" style="width:${prev}%"></i></div>`;
}

function metric(label: string, big: string | null, unit: string, hero = false): string {
  const value = big == null
    ? `<b class="quiet">${esc(unit)}</b>`
    : `<b>${esc(big)}<small> ${esc(unit)}</small></b>`;
  return `<div class="${hero ? 'hero' : 'tile'}"><small>${esc(label)}</small>${value}</div>`;
}

function moodLabel(ratio: number): string {
  if (ratio <= 0) return '안함';
  if (ratio <= 15) return '거의 안함';
  if (ratio <= 40) return '많이 덜함';
  if (ratio <= 60) return '덜함';
  if (ratio <= 85) return '조금 덜함';
  if (ratio <= 100) return '다함';
  return '추가 학습까지';
}

function fold(title: string, count: number, side: string, body: string): string {
  const countHtml = count > 0 ? `<span class="count">${count}</span>` : '';
  const sideHtml = side ? `<span class="side">${esc(side)}</span>` : '';
  if (!body.trim()) {
    return `<article class="fold"><div class="fold-head static"><span class="ttl">${esc(title)}${countHtml}</span>${sideHtml}</div></article>`;
  }
  return `<article class="fold">
    <button type="button" class="fold-head${side ? '' : ' solo'}" aria-expanded="false">
      <span class="ttl">${esc(title)}${countHtml}</span>
      ${sideHtml}
      <i class="chev" aria-hidden="true"></i>
    </button>
    <div class="panel"><div class="clip"><div class="panel-body">${body}</div></div></div>
  </article>`;
}

function lineTitle(value: string): string {
  return `<p class="item-title">${esc(value)}</p>`;
}

function lineMeta(value: string): string {
  if (!value) return '';
  return `<p class="item-meta">${esc(value)}</p>`;
}

function lineSub(value: string): string {
  if (!value) return '';
  return `<p class="item-sub">${esc(value)}</p>`;
}

function item(body: string, box = false): string {
  return `<div class="item${box ? ' has-box' : ''}">${
    box ? '<i class="box" aria-hidden="true"></i>' : ''
  }<div class="item-body">${body}</div></div>`;
}

function childRow(name: string, meta: string): string {
  return `<p class="child"><b>${esc(name || '과제')}</b>${
    meta ? `<span>${esc(meta)}</span>` : ''
  }</p>`;
}

function childTasks(entry: Row, meta: (sub: Row) => string): string {
  return rows(entry.sub_entries).map((sub) => childRow(text(sub.title), meta(sub))).join('');
}

function tap(title: string, summary: string, detail: string, box = false): string {
  return `<button type="button" class="item tap${box ? ' has-box' : ''}" data-title="${esc(title)}">${
    box ? '<i class="box" aria-hidden="true"></i>' : ''
  }<span class="item-body">${summary}<template>${detail}</template></span></button>`;
}

function checkRows(entries: Row[]): { count: number; side: string; body: string } {
  const visible = entries.filter((entry) => num(entry.progress) != null);
  let sumToday = 0;
  let sumRemain = 0;
  for (const entry of visible) {
    sumToday += int(entry.today_progress);
    if (entry.is_extra !== true) {
      sumRemain += Math.max(0, 100 - int(entry.previous_progress));
    }
  }
  const ratio = sumRemain > 0
    ? Math.round((sumToday * 100) / sumRemain)
    : (sumToday > 0 ? 101 : 0);
  const body = visible.map((entry) => {
    const book = text(entry.book_and_course);
    const group = text(entry.title);
    const title = [book, group].filter(Boolean).join(' · ') || '(제목 없음)';
    const today = int(entry.today_progress);
    const missed = entry.outcome === 'left_behind'
      ? '숙제 안 함 (두고 옴)'
      : entry.outcome === 'not_done'
      ? '숙제 안 함'
      : '';
    const extra = [pageText(entry.page), countText(entry.count)].filter(Boolean).join(' · ');
    const dates = `내준 ${monthDay(entry.assigned_at)} · 마감 ${monthDay(entry.due_date)} · 검사 ${monthDay(entry.checked_at)}`;
    const summary = [
      lineTitle(title),
      lineMeta(missed || `+${today}%`),
      lineSub(extra),
      lineSub(dates),
      bar(num(entry.previous_progress) ?? 0, today),
    ].join('');
    const detail = childTasks(entry, (sub) =>
      [pageText(sub.page), countText(sub.count)].filter(Boolean).join(' · '));
    return detail ? tap(title, summary, detail) : item(summary);
  }).join('');
  return {
    count: visible.length,
    side: visible.length ? `${moodLabel(ratio)} ${ratio}%` : '검사 내역 없음',
    body,
  };
}

function todoRow(entry: Row): string {
  const primary = text(entry.primary);
  const hasBox = primary.startsWith('□');
  const book = text(entry.book_title);
  const line1 = book || (hasBox ? primary.replace(/^□\s*/, '') : primary);
  const right1 = text(entry.right_primary);
  const secondary = text(entry.secondary);
  const right2 = text(entry.right_secondary);
  const tertiary = text(entry.tertiary);
  const right3 = text(entry.right_tertiary);
  const summary = [
    lineTitle(line1 || '(내용 없음)'),
    lineMeta(right1 ? `${right1} 출제` : ''),
    lineSub([secondary, right2].filter(Boolean).join(' · ')),
    lineSub([tertiary, right3].filter(Boolean).join(' · ')),
  ].join('');
  const detail = childTasks(entry, (sub) =>
    [pageText(sub.page), countText(sub.count)].filter(Boolean).join(' · '));
  const name = secondary || line1 || '(내용 없음)';
  return detail ? tap(name, summary, detail, hasBox) : item(summary, hasBox);
}

function behaviorRow(entry: Row): string {
  let primary = text(entry.primary);
  const hasBox = primary.startsWith('□');
  primary = primary.replace(/^□\s*/, '');
  const match = primary.match(/\s·\s(lv\.\d+)$/);
  const level = match?.[1] ?? '';
  if (match) primary = primary.slice(0, match.index);
  const secondary = text(entry.secondary);
  const chip = level
    ? `<em class="lv">${esc(level.toUpperCase().replaceAll('.', ' '))}</em>`
    : '';
  return item([
    `<p class="item-title">${esc(primary || '(내용 없음)')}${chip}</p>`,
    lineSub(secondary),
  ].join(''), hasBox);
}

function doneBlocks(entries: Row[]): string {
  return entries.map((entry) => {
    const book = text(entry.book_and_course) || '-';
    const group = text(entry.group_title) || '(제목 없음)';
    const children = rows(entry.sub_entries);
    const summary = [
      lineTitle(book),
      lineMeta(`${Math.round(num(entry.total_progress_pct) ?? 0)}%`),
      lineSub(group),
      lineMeta(`오늘 +${Math.round(num(entry.progress_pct) ?? 0)}%`),
    ].join('');
    if (!children.length) return item(summary);
    const detail = children.map((sub) => {
      const meta = [
        pageText(sub.page),
        countText(sub.count),
        `진행 ${int(sub.progress_pct)}%`,
        `검사 ${int(sub.check_count)}회`,
        `출제 ${int(sub.assignment_count)}회`,
      ].filter(Boolean).join(' · ');
      return childRow(text(sub.title), meta);
    }).join('');
    return tap(group, summary, detail);
  }).join('');
}

function classBlocks(entries: Row[]): string {
  return entries.map((entry) => {
    const book = text(entry.book_and_course);
    const title = text(entry.title);
    const time = duration(int(entry.study_ms));
    const children = rows(entry.sub_entries);
    const summary = [
      book || time ? lineTitle(book || '(제목 없음)') : '',
      lineMeta(time),
      lineSub(title),
    ].join('');
    if (!children.length) return item(summary);
    const detail = children.map((sub) => childRow(
      text(sub.title),
      [pageText(sub.page), countText(sub.count)].filter(Boolean).join(' · '),
    )).join('');
    return tap(title || book || '(제목 없음)', summary, detail);
  }).join('');
}

function flowPercent(flow: Row, key: string): number | null {
  const total = num(flow.textbook_total_problems);
  const count = num(flow[key]);
  if (total == null || total <= 0 || count == null) return null;
  return (Math.min(Math.max(count, 0), total) * 100) / total;
}

function summaryCard(payload: Row, record: Row | null): string {
  const learning = int(payload.learning_ms);
  const stayed = stayMs(payload);
  const breakMs = Math.max(0, stayed - learning);
  const works = rows(payload.class_work_entries);
  const hasDonut = works.length > 0 || learning > 0;
  const slices: { label: string; ms: number; check: string; total: string; color: string }[] = [];
  for (let i = 0; i < works.length; i++) {
    const entry = works[i];
    const ms = int(entry.study_ms);
    if (ms <= 0) continue;
    const checks = int(entry.total_check_count);
    const passed = entry.passed === true;
    const check = checks <= 0
      ? (passed ? '검사 없이 통과' : '검사 전')
      : (passed ? `${checks}회 검사 후 통과` : `${checks}회 검사 · 진행 중`);
    const totalMin = Math.round(int(entry.total_accumulated_ms) / 60000);
    slices.push({
      label: text(entry.title) || '(제목 없음)',
      ms,
      check,
      total: totalMin > 0 ? `누적 ${totalMin}분` : '',
      color: sliceColors[i % sliceColors.length],
    });
  }
  if (breakMs > 0) {
    slices.push({
      label: '휴식',
      ms: breakMs,
      check: '',
      total: '',
      color: '#D0D0D6',
    });
  }
  const totalSlice = slices.reduce((sum, slice) => sum + slice.ms, 0);
  let cursor = 0;
  const stops = slices.map((slice) => {
    const start = totalSlice <= 0 ? 0 : (cursor / totalSlice) * 100;
    cursor += slice.ms;
    const end = totalSlice <= 0 ? 0 : (cursor / totalSlice) * 100;
    return `${slice.color} ${start}% ${end}%`;
  });
  const donut = hasDonut
    ? `<div class="donut-wrap">
        <div class="donut" style="background:${stops.length ? `conic-gradient(${stops.join(',')})` : '#E7E2D8'}">
          <span><strong>${Math.round(learning / 60000)}<em>분</em></strong><small>학습</small></span>
        </div>
        <div class="legend">${slices.map((slice) => `<div class="legend-row">
          <i style="background:${slice.color}"></i>
          <div>
            ${pair(slice.label, `${Math.round(slice.ms / 60000)}분`)}
            ${slice.check || slice.total ? `<p class="minor">${esc([slice.check, slice.total].filter(Boolean).join(' · '))}</p>` : ''}
          </div>
        </div>`).join('')}</div>
      </div>`
    : '<p class="muted">오늘 수행 기록 없음</p>';
  const flows = rows(record?.flows);
  const counts = new Map<string, number>();
  for (const flow of flows) {
    const key = `${text(flow.flow_name)}|${text(flow.book_name)}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  const flowBody = flows.length
    ? flows.map((flow) => {
      const name = text(flow.flow_name) || 'Flow';
      const book = text(flow.book_name);
      const grade = text(flow.grade_label);
      const dup = (counts.get(`${text(flow.flow_name)}|${book}`) ?? 0) > 1;
      const label = !book
        ? name
        : (dup && grade ? `${name} · ${book} (${grade})` : `${name} · ${book}`);
      const pct = flowPercent(flow, 'textbook_completed_problems');
      const before = flowPercent(flow, 'textbook_completed_before');
      const today = pct == null || before == null ? null : Math.max(0, pct - before);
      const right = pct == null
        ? (flow.progress_state === 'completed' ? '완료' : '진행 중')
        : `${Math.round(pct)}%`;
      const plus = today != null && today > 0 ? `+${Math.round(today)}%` : '';
      const clampedBefore = Math.min(100, Math.max(0, before ?? pct ?? 0));
      const clampedToday = pct == null
        ? 0
        : Math.min(Math.max(0, 100 - clampedBefore), today ?? 0);
      return `<div class="flow">
        ${pair(label, [plus, right].filter(Boolean).join('  '), flow.progress_state === 'completed' && pct == null ? 'up' : '')}
        ${pct == null ? '' : bar(clampedBefore, clampedToday, true)}
      </div>`;
    }).join('')
    : '<p class="muted">오늘 과제에 연결된 Flow 없음</p>';
  const notes = Array.isArray(payload.special_notes)
    ? payload.special_notes.map((note) => text(note)).filter(Boolean)
    : [];
  const noteBody = notes.length
    ? notes.map((note) => `<p class="note"><i></i><span>${esc(note)}</span></p>`).join('')
    : '<p class="muted">특이 사항이 없습니다.</p>';
  const partial = record?.problem_record_coverage === 'partial'
    ? '<p class="muted">문항 기록이 없는 교재는 문항 수에서 빠집니다.</p>'
    : '';
  return `<section class="card">
    <h2>수업 요약</h2>
    ${donut}
    <h3 class="flow-head">학습 Flow</h3>
    ${partial}
    ${flowBody}
    <h3>특이 사항</h3>
    ${noteBody}
  </section>`;
}

function recordCard(payload: Row, record: Row | null): string {
  if (!record) {
    return '<section class="card"><h2>학습 기록</h2><p class="muted">학습 기록 없음</p></section>';
  }
  const stayed = stayMs(payload);
  const solved = num(record.solved_problem_count);
  const firstTry = num(record.first_try_correct_count);
  const accuracy = solved == null || firstTry == null || solved <= 0
    ? null
    : String(Math.round(Math.min(firstTry, solved) * 100 / solved));
  const corrTotal = num(record.correction_required_count);
  const corrDone = Math.min(num(record.correction_success_count) ?? 0, corrTotal ?? 0);
  const passed = num(record.passed_problem_count);
  let pace: string | null = null;
  let paceUnit = '기록 없음';
  if (solved != null && (stayed <= 0 || passed == null || passed <= 0)) {
    pace = null;
    paceUnit = '없음';
  } else if (solved != null && passed != null && passed > 0) {
    const minutes = stayed / 60000 / passed;
    pace = minutes >= 10 ? minutes.toFixed(0) : minutes.toFixed(1);
    paceUnit = '분';
  }
  const pool = Object.prototype.hasOwnProperty.call(record, 'max_correction_tries');
  const avg = num(record.avg_tries_to_pass);
  const maxTries = num(record.max_correction_tries);
  const avgCell = metric(
    '평균 수정 횟수',
    solved == null || avg == null ? null : avg.toFixed(1),
    solved == null ? '기록 없음' : (avg == null ? '없음' : '회'),
    true,
  );
  let rate: string | null = null;
  let rateUnit = '기록 없음';
  if (pool && corrTotal != null && corrTotal <= 0) {
    rate = null;
    rateUnit = '없음';
  } else if (pool && corrTotal != null && corrTotal > 0) {
    rate = String(Math.round(corrDone * 100 / corrTotal));
    rateUnit = '%';
  }
  const heroes = pool
    ? [
      [
        metric('새로 푼 문제', solved == null ? null : String(solved), solved == null ? '기록 없음' : '문항', true),
        metric('정답률', accuracy, accuracy != null ? '%' : (solved == null ? '기록 없음' : '없음'), true),
      ],
      [
        metric(
          '수정한 문제',
          corrTotal == null || corrTotal <= 0 ? null : String(corrTotal),
          corrTotal == null ? '기록 없음' : (corrTotal <= 0 ? '없음' : '문항'),
          true,
        ),
        metric('수정률', rate, rateUnit, true),
      ],
      [
        avgCell,
        metric(
          '최대 수정 횟수',
          solved == null || maxTries == null ? null : String(maxTries),
          solved == null ? '기록 없음' : (maxTries == null ? '없음' : '회'),
          true,
        ),
      ],
    ]
    : [
      [
        metric('새로 푼 문제', solved == null ? null : String(solved), solved == null ? '기록 없음' : '문항', true),
        metric('정답률', accuracy, accuracy != null ? '%' : (solved == null ? '기록 없음' : '없음'), true),
      ],
      [
        metric(
          '수정한 문제',
          corrTotal == null || corrTotal <= 0 ? null : String(corrDone),
          corrTotal == null ? '기록 없음' : (corrTotal <= 0 ? '없음' : `/ ${corrTotal} 성공`),
          true,
        ),
        avgCell,
      ],
    ];
  const hwTotal = num(record.homework_problem_total);
  const hwSolved = num(record.homework_problem_solved);
  const homeworkTotal = int(record.homework_total);
  const assignmentTotal = int(record.assignment_total);
  let hwBig: string | null = null;
  let hwUnit = homeworkTotal > 0 ? '기록 없음' : '없음';
  if (hwTotal != null && hwSolved != null && hwTotal <= 0) {
    hwBig = null;
    hwUnit = '없음';
  } else if (hwTotal != null && hwSolved != null) {
    hwBig = String(Math.min(hwSolved, hwTotal));
    hwUnit = `/ ${hwTotal}`;
  }
  const tiles = [
    metric(
      '완료한 숙제',
      homeworkTotal > 0 ? String(int(record.homework_completed)) : null,
      homeworkTotal > 0 ? `/ ${homeworkTotal}` : '없음',
    ),
    metric('숙제로 푼 문항', hwBig, hwUnit),
    metric(
      '완료한 과제',
      assignmentTotal > 0 ? String(int(record.assignment_completed)) : null,
      assignmentTotal > 0 ? `/ ${assignmentTotal}` : '없음',
    ),
    metric('문항 당 진행속도', pace, paceUnit),
  ];
  return `<section class="card">
    <h2>학습 기록</h2>
    ${heroes.map((line) => `<div class="metrics">${line.join('')}</div>`).join('')}
    <div class="tiles">${tiles.join('')}</div>
  </section>`;
}

function classClock(value: unknown): string {
  return text(value)
    .replaceAll(/^\(|\)$/g, '')
    .replace(/^[월화수목금토일]\s+/, '')
    .replaceAll(' - ', ' – ')
    .trim();
}

function sessionLabel(sessionDate: string): string {
  const date = new Date(`${sessionDate.slice(0, 10)}T12:00:00+09:00`);
  if (Number.isNaN(date.getTime())) return sessionDate;
  const day = new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date).replaceAll('. ', '.').replace(/\.$/, '');
  const week = new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    weekday: 'short',
  }).format(date).replace('요일', '');
  return `${day} (${week})`;
}

export function renderSheet(payload: Row): { student: string; who: string; body: string } {
  const student = text(payload.student_name) || '학생';
  const academy = text(payload.academy_name);
  const date = kstDate(payload.class_date_time);
  const arrival = kstTime(payload.arrival_time);
  const departure = kstTime(payload.departure_time);
  const clock = classClock(payload.class_time_text);
  const record = payload.lesson_record !== null && typeof payload.lesson_record === 'object'
    ? payload.lesson_record as Row
    : null;
  const checks = checkRows(rows(payload.check_rates));
  const todos = rows(payload.todo_entries);
  const done = rows(payload.completed_summaries);
  const classes = rows(payload.class_work_entries);
  const behaviors = rows(payload.behavior_entries);
  const feedback = text(payload.behavior_feedback);
  const due = parsed(payload.due_date);
  const dueText = due
    ? `${monthDay(payload.due_date)} (${weekdayKo(payload.due_date)}) 검사`
    : '검사일 미정';
  const classMinutes = classes.reduce((sum, entry) => sum + int(entry.study_ms), 0);
  const behaviorBody = [
    behaviors.map(behaviorRow).join(''),
    feedback ? `<p class="feedback">${esc(feedback)}</p>` : '',
  ].join('');
  const folds = [
    fold('숙제 검사 내역', checks.count, checks.side, checks.body),
    fold(
      '다음 숙제',
      todos.length,
      todos.length ? dueText : '숙제 없음',
      todos.map(todoRow).join(''),
    ),
    fold(
      '오늘 완료한 과제',
      done.length,
      done.length ? '' : '완료 과제 없음',
      doneBlocks(done),
    ),
    fold(
      '수업 내용',
      classes.length,
      classes.length
        ? (classMinutes > 0 ? duration(classMinutes) : '')
        : '오늘 수행 기록 없음',
      classBlocks(classes),
    ),
    fold(
      '행동리스트',
      behaviors.length,
      behaviors.length ? '' : (feedback || '행동 없음'),
      behaviorBody,
    ),
  ].join('');
  const learningText = text(payload.learning_time_text) || duration(int(payload.learning_ms)) || '-';
  const stayText = duration(stayMs(payload)) || '-';
  const who = `<div class="who" id="who">
      ${academy ? `<p class="academy">${esc(academy)}</p>` : ''}
      <h1>${esc(student)}</h1>
      <p class="when">${esc([date, text(payload.class_name)].filter(Boolean).join(' · '))}</p>
      ${clock ? `<p class="clock">수업 ${esc(clock)}</p>` : ''}
    </div>`;
  const body = `<div class="times">
      <div><small>등원</small><b>${esc(arrival || '-')}</b></div>
      <div><small>하원</small><b>${esc(departure || '-')}</b></div>
      <div><small>학습 시간</small><b>${esc(learningText)}</b></div>
      <div><small>머문 시간</small><b>${esc(stayText)}</b></div>
    </div>
    ${summaryCard(payload, record)}
    ${recordCard(payload, record)}
    ${folds}`;
  return { student, who, body };
}

export type SheetView = {
  id: string;
  label: string;
  className: string;
  who: string;
  body: string;
};

export function renderDocument(student: string, sheets: SheetView[], currentId: string): string {
  const current = sheets.find((sheet) => sheet.id === currentId) ?? sheets[0];
  const list = sheets.map((sheet) => {
    const on = sheet.id === current.id;
    return `<button type="button" class="past-item${on ? ' current' : ''}" data-id="${esc(sheet.id)}">
      <span><b>${esc(sheet.label)}</b><small>${esc(sheet.className || '정규 수업')}</small></span>
      <em${on ? '' : ' hidden'}>보는 중</em>
    </button>`;
  }).join('');
  const stored = sheets.map((sheet) =>
    `<template id="tpl-${esc(sheet.id)}"><div class="who">${sheet.who.replace(' id="who"', '')}</div><div class="view-body">${sheet.body}</div></template>`
  ).join('');
  return `<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex">
  <title>${esc(student)} 학습 리포트</title>
  <style>
    :root { color-scheme: light; }
    * { box-sizing: border-box; }
    html, body, .past-list, #detail-body { scrollbar-width: none; }
    html::-webkit-scrollbar, body::-webkit-scrollbar, .past-list::-webkit-scrollbar, #detail-body::-webkit-scrollbar {
      width: 0; height: 0; display: none;
    }
    body {
      margin: 0;
      background: #FFFFFF;
      color: #1D1D1F;
      font-family: "Pretendard", "Malgun Gothic", "Apple SD Gothic Neo", sans-serif;
      word-break: keep-all;
      overflow-wrap: break-word;
    }
    main { max-width: 480px; margin: 0 auto; padding: 28px 18px 56px; }
    .top { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
    .who { min-width: 0; flex: 1; }
    .academy { margin: 0; color: #636369; font-size: 13px; font-weight: 600; }
    h1 { margin: 8px 0 0; font-size: 32px; line-height: 1.15; font-weight: 700; }
    .when, .clock { margin: 8px 0 0; color: #636369; font-size: 15px; }
    .past-btn, .past-close {
      flex: none; border: 0; background: #F3F3F6; color: #1D1D1F;
      border-radius: 12px; padding: 10px 12px; font: inherit; font-size: 13px; font-weight: 700; cursor: pointer;
    }
    .past-btn { margin-top: 2px; }
    .times { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 18px; }
    .times div { background: #F3F3F6; border-radius: 14px; padding: 10px 12px; }
    .times small { display: block; color: #8E8E94; font-size: 12px; }
    .times b { display: block; margin-top: 2px; font-size: 16px; }
    .card, .fold { background: #F3F3F6; border-radius: 14px; }
    .card { margin-top: 14px; padding: 16px 14px 14px; }
    h2 { margin: 0; font-size: 18px; font-weight: 800; }
    h3 { margin: 16px 0 8px; color: #636369; font-size: 13px; font-weight: 700; }
    h3.flow-head { margin: 24px 0 12px; }
    .muted, .minor, .sub, .hero small, .tile small { color: #636369; }
    .muted { margin: 8px 0 0; font-size: 14px; }
    .donut-wrap { display: flex; gap: 10px; align-items: flex-start; margin-top: 14px; }
    .donut { width: 132px; height: 132px; border-radius: 50%; position: relative; flex: none; }
    .donut span {
      position: absolute; inset: 28px; background: #F3F3F6; border-radius: 50%;
      display: flex; flex-direction: column; align-items: center; justify-content: center;
    }
    .donut strong {
      display: flex; align-items: baseline; justify-content: center; white-space: nowrap;
      font-size: 20px; line-height: 1;
    }
    .donut em, .donut small { font-style: normal; color: #636369; font-size: 12px; font-weight: 700; }
    .donut small { display: block; margin-top: 3px; font-weight: 600; }
    .legend { flex: 1; min-width: 0; }
    .legend-row { display: flex; gap: 8px; margin-top: 12px; }
    .legend-row .minor { margin-top: 6px; }
    .legend-row > i { width: 8px; height: 8px; border-radius: 2px; margin-top: 6px; flex: none; }
    .legend-row > div { min-width: 0; flex: 1; }
    .legend-row .pair { margin-top: 0; }
    .pair { display: flex; justify-content: space-between; gap: 10px; align-items: baseline; margin-top: 6px; }
    .pair p { margin: 0; min-width: 0; font-size: 14px; font-weight: 700; line-height: 1.35; }
    .pair span, .up { color: #1CA058; font-weight: 700; }
    .pair.minor p, .pair.minor span { color: #636369; font-size: 12px; font-weight: 600; }
    .legend-row .pair span { color: #1D1D1F; }
    .pair .subright { color: #636369; }
    .miss { color: #1CA058; }
    .sub, .minor, .feedback { margin: 4px 0 0; font-size: 13px; line-height: 1.4; }
    .bar { position: relative; height: 5px; margin-top: 8px; border-radius: 3px; background: #FFFFFF; overflow: hidden; }
    .bar.thin { height: 4px; background: #FFFFFF; }
    .bar i { position: absolute; inset: 0 auto 0 0; }
    .bar .add { background: #1CA058; }
    .bar .prev { background: #C2C2C9; }
    .flow { margin-top: 15px; }
    .note { display: flex; gap: 8px; align-items: flex-start; margin: 8px 0 0; font-size: 14px; }
    .note i { width: 6px; height: 6px; margin-top: 6px; border-radius: 50%; background: #1CA058; flex: none; }
    .metrics, .tiles { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 12px; }
    .hero b, .tile b { display: block; margin-top: 3px; }
    .hero b { font-size: 26px; letter-spacing: -0.03em; }
    .tile { background: #FFFFFF; border-radius: 12px; padding: 10px 12px; }
    .tile b { font-size: 18px; }
    .hero b small, .tile b small { font-size: 12px; font-weight: 600; color: #636369; }
    .quiet { font-size: 14px !important; font-weight: 600; color: #636369; }
    .fold { margin-top: 10px; overflow: hidden; }
    .fold-head {
      width: 100%; border: 0; background: transparent; color: inherit; font: inherit; text-align: left;
      padding: 14px; display: grid; grid-template-columns: minmax(0, 1fr) 18px;
      column-gap: 12px; row-gap: 2px; align-items: center; cursor: pointer;
      border-radius: 14px 14px 0 0;
      -webkit-tap-highlight-color: transparent;
    }
    .fold:not(.open) > .fold-head { border-radius: 14px; }
    .fold-head:active { background: rgba(29, 29, 31, 0.05); }
    .fold-head:focus { outline: none; }
    .fold-head.static { cursor: default; grid-template-columns: minmax(0, 1fr); }
    .ttl { grid-column: 1; grid-row: 1; font-size: 17px; font-weight: 800; line-height: 1.3; }
    .count { margin-left: 6px; color: #8E8E94; font-weight: 700; }
    .side { grid-column: 1; grid-row: 2; color: #1CA058; font-size: 13px; font-weight: 700; line-height: 1.35; }
    .chev {
      grid-column: 2; grid-row: 1 / span 2; justify-self: end;
      width: 8px; height: 8px; border-right: 2px solid #8E8E94; border-bottom: 2px solid #8E8E94;
      transform: rotate(-45deg); transition: transform 340ms cubic-bezier(.22,.8,.24,1);
    }
    .fold-head.solo .chev { grid-row: 1; }
    .fold.open .chev { transform: rotate(45deg); }
    .panel, .detail { display: grid; grid-template-rows: 0fr; transition: grid-template-rows 340ms cubic-bezier(.22,.8,.24,1); }
    .fold.open > .panel, .block.open > .detail { grid-template-rows: 1fr; }
    .clip { min-height: 0; overflow: hidden; border-radius: 0 0 14px 14px; }
    .fold.settled > .panel > .clip, .block.settled .detail > .clip { overflow: visible; }
    .panel-body, .detail-body { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
    .panel-body { padding: 0 12px 14px; }
    .item {
      background: #FFFFFF; border-radius: 12px; padding: 12px; min-width: 0;
    }
    button.item.tap {
      position: relative; display: block; width: 100%; border: 0; font: inherit; color: inherit;
      text-align: left; cursor: pointer; padding-right: 28px;
      -webkit-tap-highlight-color: transparent;
    }
    button.item.tap:focus { outline: none; }
    button.item.tap:active { background: #F7F7F8; }
    button.item.tap.has-box { display: grid; padding-right: 28px; }
    button.item.tap::after {
      content: ""; position: absolute; right: 14px; top: 18px; width: 7px; height: 7px;
      border-right: 2px solid #8E8E94; border-bottom: 2px solid #8E8E94; transform: rotate(-45deg);
    }
    .item.has-box, .item.block.has-box { display: grid; grid-template-columns: 16px minmax(0, 1fr); gap: 10px; align-items: start; }
    .item-body { min-width: 0; }
    .item-title { margin: 0; font-size: 15px; font-weight: 700; line-height: 1.4; }
    .item-meta { margin: 4px 0 0; color: #1CA058; font-size: 13px; font-weight: 700; line-height: 1.4; }
    .item-sub { margin: 4px 0 0; color: #636369; font-size: 13px; line-height: 1.45; }
    #detail-body .child {
      display: flex; justify-content: space-between; align-items: baseline; gap: 16px; margin: 0;
    }
    #detail-body .child b {
      min-width: 0; flex: 1; text-align: left; font-weight: 700; font-size: 14px; line-height: 1.4;
    }
    #detail-body .child span {
      flex: none; max-width: 58%; text-align: right; color: #636369; font-size: 13px; font-weight: 600; line-height: 1.4;
    }
    .box {
      width: 14px; height: 14px; margin-top: 3px; border: 1.5px solid #A8A8B0; border-radius: 4px;
    }
    .more {
      display: inline-block; margin-top: 8px; padding: 0; border: 0; background: none;
      color: #1CA058; font: inherit; font-size: 13px; font-weight: 700; cursor: pointer;
    }
    .lv {
      display: inline-block; margin-left: 6px; font-style: normal; background: #F3F3F6;
      border-radius: 8px; padding: 1px 6px; color: #636369; font-size: 11px; font-weight: 700;
    }
    .feedback { margin: 0; color: #1D1D1F; font-size: 14px; line-height: 1.45; }
    .scrim {
      position: fixed; inset: 0; border: 0; background: rgba(29, 29, 31, 0.28); cursor: pointer;
    }
    .past-panel {
      position: fixed; left: 50%; bottom: 0; transform: translateX(-50%);
      width: min(480px, 100%); max-height: min(72vh, 640px);
      background: #FFFFFF; border-radius: 18px 18px 0 0;
      display: flex; flex-direction: column; box-shadow: 0 -8px 30px rgba(29, 29, 31, 0.08);
    }
    .past-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; padding: 16px 16px 8px; }
    .past-head h2 { margin: 0; min-width: 0; font-size: 18px; line-height: 1.35; }
    .past-list { overflow: auto; padding: 8px 16px 20px; display: flex; flex-direction: column; gap: 8px; }
    .past-item {
      width: 100%; border: 0; background: #F3F3F6; color: inherit; font: inherit; text-align: left;
      border-radius: 12px; padding: 14px; display: flex; align-items: center; justify-content: space-between; gap: 12px; cursor: pointer;
    }
    .past-item b { display: block; font-size: 15px; }
    .past-item small { display: block; margin-top: 4px; color: #636369; font-size: 12px; font-weight: 600; }
    .past-item em { font-style: normal; color: #1CA058; font-size: 12px; font-weight: 700; white-space: nowrap; }
    #past[hidden], #detail[hidden] { display: none; }
    #detail-body .bar { background: #F3F3F6; }
    #detail-body .item-title { margin-top: 10px; }
    @media (prefers-reduced-motion: reduce) {
      .panel, .detail, .chev { transition: none; }
    }
  </style>
</head>
<body>
  <main>
    <div class="top">
      ${current.who}
      <button type="button" class="past-btn" id="past-open">이전 알림장</button>
    </div>
    <div id="view">${current.body}</div>
  </main>
  <div id="detail" hidden>
    <button type="button" class="scrim" id="detail-scrim" aria-label="닫기"></button>
    <div class="past-panel" role="dialog" aria-modal="true" aria-labelledby="detail-title">
      <div class="past-head">
        <h2 id="detail-title">상세</h2>
        <button type="button" class="past-close" id="detail-close">닫기</button>
      </div>
      <div class="past-list" id="detail-body"></div>
    </div>
  </div>
  <div id="past" hidden>
    <button type="button" class="scrim" id="past-scrim" aria-label="닫기"></button>
    <div class="past-panel" role="dialog" aria-modal="true" aria-labelledby="past-title">
      <div class="past-head">
        <h2 id="past-title">이전 알림장</h2>
        <button type="button" class="past-close" id="past-close">닫기</button>
      </div>
      <div class="past-list">${list}</div>
    </div>
  </div>
  ${stored}
  <script>
    const past = document.getElementById('past');
    const openPast = () => { past.hidden = false; };
    const closePast = () => { past.hidden = true; };
    document.getElementById('past-open').addEventListener('click', openPast);
    document.getElementById('past-close').addEventListener('click', closePast);
    document.getElementById('past-scrim').addEventListener('click', closePast);
    const detail = document.getElementById('detail');
    const closeDetail = () => { detail.hidden = true; };
    document.getElementById('detail-close').addEventListener('click', closeDetail);
    document.getElementById('detail-scrim').addEventListener('click', closeDetail);

    function bindSheet(root) {
      root.querySelectorAll('.fold').forEach((fold) => {
        const button = fold.querySelector(':scope > .fold-head');
        if (!button || button.classList.contains('static')) return;
        button.addEventListener('click', () => {
          const willOpen = !fold.classList.contains('open');
          root.querySelectorAll('.fold').forEach((other) => {
            other.classList.remove('open', 'settled');
            const otherButton = other.querySelector(':scope > .fold-head');
            if (otherButton) otherButton.setAttribute('aria-expanded', 'false');
          });
          if (willOpen) {
            fold.classList.add('open');
            button.setAttribute('aria-expanded', 'true');
            window.setTimeout(() => {
              if (fold.classList.contains('open')) fold.classList.add('settled');
            }, 380);
          }
        });
        const panel = fold.querySelector(':scope > .panel');
        panel?.addEventListener('transitionend', (event) => {
          if (event.target !== panel || event.propertyName !== 'grid-template-rows') return;
          fold.classList.toggle('settled', fold.classList.contains('open'));
        });
      });
      root.querySelectorAll('.tap').forEach((button) => {
        button.addEventListener('click', () => {
          const tpl = button.querySelector('template');
          const body = document.getElementById('detail-body');
          body.replaceChildren();
          if (tpl) body.append(tpl.content.cloneNode(true));
          document.getElementById('detail-title').textContent = button.dataset.title || '상세';
          detail.hidden = false;
        });
      });
    }

    function showSheet(id) {
      const tpl = document.getElementById('tpl-' + id);
      if (!tpl) return;
      const frag = tpl.content.cloneNode(true);
      const who = frag.querySelector('.who');
      const body = frag.querySelector('.view-body');
      who.id = 'who';
      document.getElementById('who').replaceWith(who);
      const view = document.getElementById('view');
      view.replaceChildren();
      while (body.firstChild) view.appendChild(body.firstChild);
      bindSheet(view);
      document.querySelectorAll('.past-item').forEach((button) => {
        const on = button.dataset.id === id;
        button.classList.toggle('current', on);
        const mark = button.querySelector('em');
        if (mark) mark.hidden = !on;
      });
      closePast();
      closeDetail();
      window.scrollTo(0, 0);
    }

    document.querySelectorAll('.past-item').forEach((button) => {
      button.addEventListener('click', () => showSheet(button.dataset.id || ''));
    });
    bindSheet(document.getElementById('view'));
  </script>
</body>
</html>`;
}

function page(html: string, status = 200): Response {
  return new Response(html, {
    status,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'private, no-store',
      'Referrer-Policy': 'no-referrer',
      'X-Robots-Tag': 'noindex',
    },
  });
}

function missing(message: string): Response {
  return page(
    `<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>알림장</title><body style="font-family:sans-serif;padding:32px;color:#1D1D1F"><p>${esc(message)}</p></body></html>`,
    404,
  );
}

if (import.meta.main) Deno.serve(async (req) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return page('<p>잘못된 요청입니다.</p>', 405);
  }
  const token = (new URL(req.url).searchParams.get('t') ?? '').trim();
  if (!/^[0-9a-f]{32,64}$/i.test(token)) return missing('알림장을 찾을 수 없습니다.');

  const admin = createAdminClient();
  const { data: link, error: linkError } = await admin
    .from('todo_sheet_share_links')
    .select('snapshot_id, student_id')
    .eq('token', token)
    .maybeSingle();
  if (linkError || !link?.snapshot_id || !link.student_id) {
    return missing('알림장을 찾을 수 없습니다.');
  }

  const { data: snapshots, error: snapshotError } = await admin
    .from('student_class_session_todo_sheet_snapshots')
    .select('id, session_date, class_name, payload')
    .eq('student_id', link.student_id)
    .order('session_date', { ascending: false })
    .order('finalized_at', { ascending: false })
    .limit(40);
  if (snapshotError || !snapshots?.length) return missing('알림장을 불러오지 못했습니다.');

  const sheets: SheetView[] = [];
  let studentName = '';
  let fallbackName = '학생';
  for (const row of snapshots) {
    if (!row?.payload || typeof row.payload !== 'object' || !row.id) continue;
    const payload = row.payload as Row;
    const view = renderSheet(payload);
    const id = String(row.id);
    if (!sheets.length) fallbackName = view.student;
    if (id === String(link.snapshot_id)) studentName = view.student;
    const span = [kstTime(payload.arrival_time), kstTime(payload.departure_time)]
      .filter(Boolean)
      .join('–');
    sheets.push({
      id,
      label: sessionLabel(String(row.session_date ?? '')),
      className: [text(row.class_name) || text(payload.class_name) || '정규 수업', span]
        .filter(Boolean)
        .join(' · '),
      who: view.who,
      body: view.body,
    });
  }
  if (!sheets.length) return missing('알림장을 불러오지 못했습니다.');
  const currentId = sheets.some((sheet) => sheet.id === String(link.snapshot_id))
    ? String(link.snapshot_id)
    : sheets[0].id;
  return page(renderDocument(studentName || fallbackName, sheets, currentId));
});
