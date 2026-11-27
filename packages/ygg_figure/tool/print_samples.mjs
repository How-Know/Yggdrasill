// 임시 도구: 수능 샘플 문항(엔진 그림이 있는 문항)을 실제 인쇄 양식에 올려 본다.
//
// 실제 v2 인쇄 렌더러(renderPdfWithXeLatex)를 그대로 쓴다. 문항의 글·선지·그림 자리는 미리 받아 둔
// reference/work/csat_rows.json 에서 읽고, 그림은 이 PC 의 파일(원본: reference/images, 엔진: 내보낸 묶음)을
// 저장소 대신 돌려준다. DB 와 저장소에는 아무것도 쓰지 않는다.
//
//   node tool/print_samples.mjs <mock|naesin|assignment> [--export <묶음 폴더>] [--out <결과 폴더>] [--ppi 110]
//                               [--inline-right <그림 이름,...>] [--sizes <크기 표>] [--no-mark] [--no-tikz]
//                               [--profile <틀>] [--paper <용지>] [--original]
//
// --inline-right 로 적은 그림은 원래 자리와 상관없이 본문 오른쪽 어울림으로 싣는다(크기 기준을 눈으로 보기 위한 것).
// 적지 않으면 정해 둔 그림 6장을 쓴다. 하나도 바꾸지 않으려면 --inline-right "" 로 준다.
// 문항 글 위 한 줄에 그 그림의 크기 부류를 "대 85%" 처럼 밑줄을 그어 임시로 적는다(--no-mark 로 끈다).
// 그림은 그리는 글(TikZ)을 인쇄 문서가 직접 조판한다(그림 속 글자가 본문 글꼴로 찍힌다). --no-tikz 면 PDF 그림을 넣는다.
// --original 이면 엔진 그림 대신 시험지에서 꺼낸 원본 그림을 싣는다(원본 그림의 배치를 확인할 때 쓴다).
// 끝나면 결과 폴더에 sized.pdf, page-N.png, result.json 이 생긴다.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const pkg = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.resolve(pkg, '..', '..');
const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i < 0 ? null : process.argv[i + 1];
};

// 원본은 모두 본문 아래 그림이다. 오른쪽 어울림 크기도 볼 수 있게 몇 장을 임의로 어울림으로 싣는다.
const INLINE_RIGHT = [
  'csat-2018-na-4-1',
  'csat-2023-common-13-1',
  'csat-2024-common-13-1',
  'csat-2024-common-14-1',
  'csat-2026-common-4-1',
  'csat-2026-geometry-27-1',
];
// 양식마다 실제로 찍는 틀과 용지. 학습앱이 인쇄를 맡길 때 보내는 값과 같게 둔다
// (apps/yggdrasill 의 LearningProblemExportSettings 와 problem_bank_view.dart 의 양식 선택:
//  과제형은 A4, 내신형은 학교 틀(기본 경신중)·B4, 모의고사형은 8절. 모두 2단·한 쪽 4문항·KoPub 바탕 11).
// mark: 문항 글 위 한 줄에 그림의 크기 부류(소·중·대·오른쪽 어울림)를 임시로 적는다.
const FORMATS = {
  mock: { profile: 'csat', paper: '8절', columns: 2, perPage: 4, renumber: true, mark: true, inlineRight: INLINE_RIGHT, renderConfig: { hidePreviewHeader: true } },
  naesin: { profile: 'gyeongsin', paper: 'B4', columns: 2, perPage: 4, renumber: true, mark: true, inlineRight: INLINE_RIGHT, renderConfig: { hidePreviewHeader: true } },
  assignment: {
    profile: 'assignment',
    paper: 'A4',
    columns: 2,
    perPage: 4,
    renumber: true,
    mark: true,
    inlineRight: INLINE_RIGHT,
    renderConfig: {
      questionNumberPlacement: 'above',
      questionNumberFormat: 'two_digit',
      titlePageIndices: [1],
      titlePageHeaders: [{ page: 1, title: '수학 영역', subtitle: '' }],
      titlePageTopText: '그림 크기 샘플',
      titlePageGoalText: '과제형',
    },
  },
};
const format = process.argv[2];
if (!FORMATS[format]) {
  console.error('양식은 mock, naesin, assignment 중 하나입니다.');
  process.exit(2);
}
const { columns, perPage, renumber, renderConfig, mark = false, inlineRight: defaultInlineRight = [] } = FORMATS[format];
// --profile, --paper: 같은 양식 안의 다른 틀·용지로 찍어 볼 때만 쓴다(예: 내신형의 다른 학교 틀).
const profile = arg('--profile') || FORMATS[format].profile;
const paper = arg('--paper') || FORMATS[format].paper;
const marking = mark && !process.argv.includes('--no-mark');
const useTikz = !process.argv.includes('--no-tikz');
const exportDir = path.resolve(arg('--export') || path.join(pkg, 'build/export'));
const out = path.resolve(arg('--out') || path.join(pkg, 'build/samples', format));
const ppi = String(arg('--ppi') || 110);
const inlineRight = new Set(
  arg('--inline-right') == null ? defaultInlineRight : arg('--inline-right').split(',').map((s) => s.trim()).filter(Boolean),
);
// 학습앱의 기본 글꼴(KoPub 바탕). 앱에 들어 있는 글꼴 파일을 그대로 쓴다.
const bodyFont = path.join(root, 'apps/yggdrasill/assets/fonts/kopub/KoPubWorldBatangProLight.otf');

// 크기 표에 적힌 이 양식의 본문 너비(글자 수). 표시에 "본문 너비의 몇 %" 를 적는 데만 쓴다.
const sizesFile = path.resolve(arg('--sizes') || path.join(pkg, 'figures/size_table.json'));
const columnEm = fs.existsSync(sizesFile) ? Number(JSON.parse(fs.readFileSync(sizesFile, 'utf8')).columns?.[format]) : NaN;
const CLASS_NAMES = { small: '소', medium: '중', large: '대' };

const rowsFile = path.join(pkg, 'reference/work/csat_rows.json');
if (!fs.existsSync(rowsFile)) {
  console.error(`샘플 문항 파일이 없습니다: ${rowsFile}`);
  process.exit(2);
}
const load = (rel) => import(pathToFileURL(path.join(root, rel)).href);
const { renderPdfWithXeLatex } = await load('gateway/src/problem_bank/render_engine/xelatex_v2/renderer.js');
const { buildEngineFigureRecord, figureSizePosition, storedFigurePosition } = await load('gateway/src/problem_bank/engine_figures.js');

const rows = JSON.parse(fs.readFileSync(rowsFile, 'utf8')).rows;
const manifest = JSON.parse(fs.readFileSync(path.join(pkg, 'reference/manifest.json'), 'utf8')).figures;
const bundles = fs.readdirSync(exportDir)
  .filter((name) => fs.existsSync(path.join(exportDir, name, 'asset.json')))
  .map((name) => JSON.parse(fs.readFileSync(path.join(exportDir, name, 'asset.json'), 'utf8')))
  .sort((a, b) => a.id.localeCompare(b.id));

// 저장소 흉내: 원본 그림 자리는 시험지에서 꺼낸 원본을, 엔진 그림 자리는 엔진이 낸 PDF 를 돌려준다.
const localFiles = new Map();
const client = {
  storage: {
    from: (bucket) => ({
      download: async (objectPath) => {
        const file = localFiles.get(`${bucket}/${objectPath}`);
        if (!file || !fs.existsSync(file)) return { data: null, error: new Error(`no local file for ${bucket}/${objectPath}`) };
        return { data: new Blob([fs.readFileSync(file)]), error: null };
      },
    }),
  },
};

const questions = [];
const skipped = [];
const figures = [];
for (const bundle of bundles) {
  // 그림 이름이 곧 원본 목록의 이름이다. 원본 그림이 따로 없어 다른 그림을 겹쳐 본 그림(ref 가 다른 그림)도 자기 문항에 싣는다.
  const entry = manifest.find((f) => f.id === bundle.id) || manifest.find((f) => f.id === bundle.ref);
  const row = entry && rows.find((r) => r.pb_question_id === entry.pb_question_id);
  const assets = row && Array.isArray(row.figure_assets) ? row.figure_assets : [];
  const asset = assets.find((a) => Number(a.figure_index) === Number(entry?.figure_order));
  if (!entry || !row || !asset) {
    skipped.push(bundle.id);
    continue;
  }
  for (const a of assets) {
    const original = manifest.find((f) => f.pb_question_id === entry.pb_question_id && Number(f.figure_order) === Number(a.figure_index));
    if (!original) continue;
    // 시험지에서 따로 꺼내지 못한 그림(same_as 가 적힌 것)은 같은 그림의 원본을 쓴다.
    const file = [original.id, original.same_as].filter(Boolean)
      .map((id) => path.join(pkg, 'reference/images', `${id}.png`)).find((f) => fs.existsSync(f));
    if (file) localFiles.set(`${a.bucket}/${a.path}`, file);
  }
  // 자리: 저장된 배치 그대로. --inline-right 로 고른 그림만 본문 오른쪽으로 바꾼다.
  const assetKey = `idx:${entry.figure_order}`;
  let layout = row.figure_layout || null;
  if (inlineRight.has(bundle.id)) {
    const items = Array.isArray(layout?.items) ? layout.items.filter((one) => one?.assetKey !== assetKey) : [];
    const old = Array.isArray(layout?.items) ? layout.items.find((one) => one?.assetKey === assetKey) : null;
    layout = { version: 1, groups: [], ...(layout || {}), items: [...items, { anchor: 'center', offsetXEm: 0, offsetYEm: 0, ...(old || {}), assetKey, position: 'inline-right' }] };
  }
  const position = figureSizePosition(storedFigurePosition({ figure_layout: layout }, entry.figure_order, 1));
  const base = `samples/${entry.pb_question_id}/${entry.figure_order}`;
  localFiles.set(`problem-figures/${base}/figure.pdf`, path.join(exportDir, bundle.id, 'figure.pdf'));
  const variantPdfPaths = {};
  const variantTikzPaths = {};
  const baseTikz = useTikz && bundle.files?.tikz ? `${base}/${bundle.files.tikz}` : '';
  if (baseTikz) localFiles.set(`problem-figures/${baseTikz}`, path.join(exportDir, bundle.id, bundle.files.tikz));
  let markText = '';
  for (const v of bundle.variants || []) {
    variantPdfPaths[`${v.format}/${v.position}`] = `${base}/${v.pdf}`;
    localFiles.set(`problem-figures/${base}/${v.pdf}`, path.join(exportDir, bundle.id, v.pdf));
    if (useTikz && v.tikz) {
      variantTikzPaths[`${v.format}/${v.position}`] = `${base}/${v.tikz}`;
      localFiles.set(`problem-figures/${base}/${v.tikz}`, path.join(exportDir, bundle.id, v.tikz));
    }
    // 이 문항에 실제로 실리는 자리의 크기만 적는다.
    if (v.format === format && v.position === position) {
      const name = position === 'inline-right' ? '오른쪽 어울림' : CLASS_NAMES[bundle.size_class] || '';
      const percent = columnEm > 0 ? ` ${Math.round((v.width_em / columnEm) * 100)}%` : '';
      if (marking && name) markText = `[밑줄]${name}${percent}[/밑줄]\n[문단]\n`;
      figures.push({
        id: bundle.id,
        number: questions.length + 1,
        kind: bundle.kind || '',
        size_class: bundle.size_class || '',
        position: v.position,
        width_em: v.width_em,
        height_em: v.height_em,
        scale: v.scale,
        source: v.source,
        needs_check: v.needs_check === true,
      });
    }
  }
  const choices = Array.isArray(row.choices) ? row.choices : [];
  questions.push({
    id: entry.pb_question_id,
    question_uid: entry.pb_question_id,
    question_number: String(renumber ? questions.length + 1 : row.problem_number),
    stem: `${markText}${row.stem}`,
    equations: [],
    choices,
    objective_choices: choices,
    allow_objective: choices.length > 0,
    allow_subjective: choices.length === 0,
    export_mode: choices.length > 0 ? 'objective' : 'subjective',
    figure_refs: assets.map(() => '[그림]'),
    meta: {
      figure_assets: assets,
      ...(layout ? { figure_layout: layout } : {}),
      engine_figures: [buildEngineFigureRecord({
        bundle,
        figureIndex: entry.figure_order,
        originalPath: asset.path,
        pdfPath: `${base}/figure.pdf`,
        variantPdfPaths,
        tikzPath: baseTikz,
        variantTikzPaths,
        status: 'approved',
      })],
    },
  });
}

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
// 렌더러가 찍는 진행 기록은 표준 출력을 어지럽히므로 오류 쪽으로 돌린다.
const log = console.log;
console.log = (...a) => console.error(...a);
const rendered = await renderPdfWithXeLatex({
  questions,
  renderConfig: { engineFigures: !process.argv.includes('--original'), ...renderConfig },
  profile,
  paper,
  layoutColumns: columns,
  maxQuestionsPerPage: perPage,
  questionMode: 'objective',
  ...(fs.existsSync(bodyFont)
    ? { fontFamilyRequested: 'KoPubWorldBatangPro', fontFamilyResolved: 'KoPubWorldBatangPro', fontRegularPath: bodyFont, fontBoldPath: bodyFont }
    : {}),
  fontSize: 11,
  supabaseClient: client,
});
console.log = log;
const pdf = path.join(out, 'sized.pdf');
fs.writeFileSync(pdf, rendered.bytes);
execFileSync('pdftoppm', ['-png', '-r', ppi, pdf, path.join(out, 'page')]);
const pages = fs.readdirSync(out).filter((n) => /^page-\d+\.png$/.test(n)).sort((a, b) => parseInt(a.slice(5), 10) - parseInt(b.slice(5), 10));
const result = {
  format, profile, paper, columns,
  questions: questions.length,
  engine_figures: rendered.figureHydration?.engineFigureCount ?? 0,
  skipped,
  pdf,
  pages: pages.map((n) => path.join(out, n)),
  figures,
};
fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify(result, null, 2));
console.log(JSON.stringify({ questions: result.questions, engine_figures: result.engine_figures, pages: pages.length, out }));
