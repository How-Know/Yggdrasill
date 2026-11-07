import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const BUNDLED_LOGOS = {
  경신중: 'gyeongsin_logo.png',
  능인중: 'neungin_logo.png',
  소선여중: 'soseon_logo.png',
  정화중: 'jeonghwa_logo.png',
  황금중: 'hwanggeum_logo.png',
};

const DEFAULT_SCHOOL_KEY = '경신중';

// 학습앱 NaesinExamContext.canonicalSchoolName 과 같은 접미사 규칙.
export function naesinSchoolKey(raw) {
  const compact = String(raw || '').replace(/\s+/g, '').trim();
  if (!compact) return '';
  return compact
    .replace(/여자중학교$/, '여중')
    .replace(/여자고등학교$/, '여고')
    .replace(/중학교$/, '중')
    .replace(/고등학교$/, '고');
}

export function schoolDisplayName(key) {
  const k = String(key || '').trim();
  if (!k) return '';
  if (/여중$/.test(k)) return k.replace(/여중$/, '여자중학교');
  if (/여고$/.test(k)) return k.replace(/여고$/, '여자고등학교');
  if (/중$/.test(k)) return `${k}학교`;
  if (/고$/.test(k)) return `${k}등학교`;
  return k;
}

async function schoolKeyFromQuestions(questions, supabaseClient) {
  const directKeys = new Set(
    (questions || [])
      .map((q) => naesinSchoolKey(
        q?.school_name || q?.schoolName || q?.meta?.school_name || q?.meta?.schoolName || '',
      ))
      .filter(Boolean),
  );
  if (directKeys.size === 1) return [...directKeys][0];
  if (!supabaseClient) return '';
  const documentIds = [...new Set(
    (questions || [])
      .map((q) => String(q?.document_id || q?.documentId || '').trim())
      .filter(Boolean),
  )];
  if (documentIds.length === 0) return '';
  const { data, error } = await supabaseClient
    .from('pb_documents')
    .select('id,school_name,source_type_code')
    .in('id', documentIds);
  if (error || !Array.isArray(data)) return '';
  const keys = new Set(
    data
      .filter((row) => String(row?.source_type_code || '').trim() === 'school_past')
      .map((row) => naesinSchoolKey(row?.school_name))
      .filter(Boolean),
  );
  return keys.size === 1 ? [...keys][0] : '';
}

async function downloadSchoolLogo(key, supabaseClient, workDir) {
  if (!supabaseClient) return { logoPath: '', displayName: '' };
  const { data: row, error } = await supabaseClient
    .from('school_logos')
    .select('display_name,logo_bucket,logo_path')
    .eq('school_key', key)
    .maybeSingle();
  if (error || !row?.logo_path) return { logoPath: '', displayName: '' };
  const displayName = String(row.display_name || '').trim();
  const bucket = String(row.logo_bucket || 'school-logos').trim();
  const { data: blob, error: dlError } = await supabaseClient.storage
    .from(bucket)
    .download(row.logo_path);
  if (dlError || !blob) return { logoPath: '', displayName };
  const ext = (path.extname(row.logo_path) || '.png').toLowerCase();
  const dst = path.join(workDir, `school_logo${ext === '.jpeg' ? '.jpg' : ext}`);
  fs.writeFileSync(dst, Buffer.from(await blob.arrayBuffer()));
  return { logoPath: dst, displayName };
}

function copyBundledLogo(key, workDir) {
  const file = BUNDLED_LOGOS[key];
  if (!file) return '';
  const src = path.resolve(path.dirname(fileURLToPath(import.meta.url)), 'assets', file);
  if (!fs.existsSync(src)) return '';
  const dst = path.join(workDir, file);
  fs.copyFileSync(src, dst);
  return dst;
}

/**
 * 내신 양식 표지 하단의 학교명·로고.
 * 선택 문항이 모두 같은 학교의 내신 기출이면 그 학교, 아니면 양식 기본 학교(경신중)다.
 * DB 에 로고가 없는 학교는 logoPath 를 비워 이름만 그린다.
 */
export async function resolveSchoolBranding({
  questions,
  supabaseClient,
  workDir,
  includeLogo = true,
  defaultSchoolKey = DEFAULT_SCHOOL_KEY,
}) {
  let key = '';
  try {
    key = await schoolKeyFromQuestions(questions, supabaseClient);
  } catch (err) {
    console.warn('[school-branding] school lookup failed:', err?.message || err);
  }
  if (!key) key = defaultSchoolKey || DEFAULT_SCHOOL_KEY;
  if (!includeLogo) {
    return { schoolKey: key, schoolName: schoolDisplayName(key), logoPath: '' };
  }
  let logoPath = '';
  let displayName = '';
  try {
    ({ logoPath, displayName } = await downloadSchoolLogo(key, supabaseClient, workDir));
  } catch (err) {
    console.warn('[school-branding] logo download failed:', err?.message || err);
  }
  if (!logoPath) logoPath = copyBundledLogo(key, workDir);
  return {
    schoolKey: key,
    schoolName: displayName || schoolDisplayName(key),
    logoPath,
  };
}
