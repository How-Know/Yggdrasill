import 'dotenv/config';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const MANIFEST_PATH =
  process.env.PB_GOLDEN_MANIFEST ||
  path.resolve('quality/problem_bank/golden_manifest.json');

function norm(value) {
  return String(value ?? '')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
}

function loadJson(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8');
  const parsed = JSON.parse(raw);
  if (Array.isArray(parsed)) return { questions: parsed };
  if (parsed && Array.isArray(parsed.questions)) return parsed;
  return { questions: [] };
}

function avg(values) {
  if (!values.length) return 0;
  return values.reduce((a, b) => a + b, 0) / values.length;
}

function hashFile(filePath) {
  const h = crypto.createHash('sha256');
  h.update(fs.readFileSync(filePath));
  return h.digest('hex');
}

function scoreQuestionCount(expected, actual) {
  const e = expected.length;
  const a = actual.length;
  if (e === 0 && a === 0) return 1;
  const diff = Math.abs(e - a);
  return Math.max(0, 1 - diff / Math.max(1, e));
}

function toChoiceSignature(q) {
  const choices = Array.isArray(q.choices) ? q.choices : [];
  return choices
    .map((c) => `${norm(c.label)}:${norm(c.text)}`)
    .join('|');
}

function toEquationSignature(q) {
  const equations = Array.isArray(q.equations) ? q.equations : [];
  if (!equations.length) return '';
  return equations
    .map((e) => norm(e.latex || e.raw || ''))
    .filter(Boolean)
    .join('|');
}

function hasFigure(q) {
  const refs = Array.isArray(q.figure_refs) ? q.figure_refs : [];
  return refs.length > 0;
}

function mapByQuestionNumber(questions) {
  const out = new Map();
  for (const q of questions) {
    const key = norm(q.question_number || q.number || '');
    if (!key) continue;
    if (!out.has(key)) out.set(key, q);
  }
  return out;
}

function compareSample(expectedQuestions, actualQuestions) {
  const byExpected = mapByQuestionNumber(expectedQuestions);
  const byActual = mapByQuestionNumber(actualQuestions);

  const choiceScores = [];
  const equationScores = [];
  const figureScores = [];

  for (const [key, eq] of byExpected.entries()) {
    const aq = byActual.get(key);
    if (!aq) {
      choiceScores.push(0);
      equationScores.push(0);
      figureScores.push(0);
      continue;
    }

    const expChoice = toChoiceSignature(eq);
    const actChoice = toChoiceSignature(aq);
    choiceScores.push(expChoice === actChoice ? 1 : 0);

    const expEq = toEquationSignature(eq);
    const actEq = toEquationSignature(aq);
    if (!expEq && !actEq) {
      equationScores.push(1);
    } else {
      equationScores.push(expEq === actEq ? 1 : 0);
    }

    figureScores.push(hasFigure(eq) === hasFigure(aq) ? 1 : 0);
  }

  return {
    questionCountAccuracy: scoreQuestionCount(expectedQuestions, actualQuestions),
    choiceAccuracy: avg(choiceScores),
    equationAccuracy: avg(equationScores),
    figureBindingAccuracy: avg(figureScores),
  };
}

function formatPct(v) {
  return `${(v * 100).toFixed(1)}%`;
}

function resolveFromManifest(baseDir, relOrAbs) {
  if (!relOrAbs) return '';
  if (path.isAbsolute(relOrAbs)) return relOrAbs;
  return path.resolve(baseDir, relOrAbs);
}

function run() {
  if (!fs.existsSync(MANIFEST_PATH)) {
    console.log(
      `[pb-quality-gate] manifest not found: ${MANIFEST_PATH} (skip)`,
    );
    process.exit(0);
  }
  const manifestRaw = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
  const baseDir = path.dirname(MANIFEST_PATH);
  const thresholds = {
    questionCountAccuracy:
      Number(manifestRaw?.thresholds?.questionCountAccuracy ?? 0.99),
    choiceAccuracy: Number(manifestRaw?.thresholds?.choiceAccuracy ?? 0.9),
    equationAccuracy: Number(manifestRaw?.thresholds?.equationAccuracy ?? 0.85),
    figureBindingAccuracy: Number(
      manifestRaw?.thresholds?.figureBindingAccuracy ?? 0.9,
    ),
    pdfHashMatch: Number(manifestRaw?.thresholds?.pdfHashMatch ?? 1.0),
  };
  const samples = Array.isArray(manifestRaw?.samples) ? manifestRaw.samples : [];
  if (!samples.length) {
    console.log('[pb-quality-gate] samples empty (skip)');
    process.exit(0);
  }

  const aggregate = {
    questionCountAccuracy: [],
    choiceAccuracy: [],
    equationAccuracy: [],
    figureBindingAccuracy: [],
    pdfHashMatch: [],
  };

  console.log(`[pb-quality-gate] run ${samples.length} samples`);
  for (const sample of samples) {
    const expectedPath = resolveFromManifest(baseDir, sample.expected);
    const actualPath = resolveFromManifest(baseDir, sample.actual);
    if (!fs.existsSync(expectedPath) || !fs.existsSync(actualPath)) {
      throw new Error(
        `sample(${sample.id || 'unknown'}) expected/actual file missing`,
      );
    }
    const expected = loadJson(expectedPath);
    const actual = loadJson(actualPath);
    const score = compareSample(expected.questions, actual.questions);

    aggregate.questionCountAccuracy.push(score.questionCountAccuracy);
    aggregate.choiceAccuracy.push(score.choiceAccuracy);
    aggregate.equationAccuracy.push(score.equationAccuracy);
    aggregate.figureBindingAccuracy.push(score.figureBindingAccuracy);

    let pdfHashMatch = 1;
    if (sample.pdfActual && sample.pdfExpectedSha256) {
      const pdfPath = resolveFromManifest(baseDir, sample.pdfActual);
      if (fs.existsSync(pdfPath)) {
        const actualHash = hashFile(pdfPath);
        pdfHashMatch =
          norm(actualHash) === norm(sample.pdfExpectedSha256) ? 1 : 0;
      } else {
        pdfHashMatch = 0;
      }
    }
    aggregate.pdfHashMatch.push(pdfHashMatch);

    console.log(
      `[pb-quality-gate] ${sample.id || '(sample)'} :: qCount=${formatPct(score.questionCountAccuracy)} choice=${formatPct(score.choiceAccuracy)} eq=${formatPct(score.equationAccuracy)} figure=${formatPct(score.figureBindingAccuracy)} pdf=${formatPct(pdfHashMatch)}`,
    );
  }

  const finalScore = {
    questionCountAccuracy: avg(aggregate.questionCountAccuracy),
    choiceAccuracy: avg(aggregate.choiceAccuracy),
    equationAccuracy: avg(aggregate.equationAccuracy),
    figureBindingAccuracy: avg(aggregate.figureBindingAccuracy),
    pdfHashMatch: avg(aggregate.pdfHashMatch),
  };

  console.log('[pb-quality-gate] summary');
  console.log(
    JSON.stringify(
      {
        thresholds,
        score: finalScore,
      },
      null,
      2,
    ),
  );

  const failed = Object.entries(thresholds).filter(([k, t]) => {
    const s = finalScore[k];
    return typeof s === 'number' && s < t;
  });

  if (failed.length) {
    console.error(
      `[pb-quality-gate] FAILED: ${failed
        .map(([k, t]) => `${k}(${formatPct(finalScore[k])} < ${formatPct(t)})`)
        .join(', ')}`,
    );
    process.exit(1);
  }
  console.log('[pb-quality-gate] PASSED');
}

try {
  run();
} catch (err) {
  console.error('[pb-quality-gate] error', String(err?.message || err));
  process.exit(1);
}
