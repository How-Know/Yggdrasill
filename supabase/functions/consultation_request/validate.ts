export function normalizePhone(raw: unknown): string | null {
  let digits = String(raw ?? '').replace(/\D/g, '');
  if (digits.startsWith('82')) digits = `0${digits.slice(2)}`;
  if (digits.startsWith('010')) return digits.length === 11 ? digits : null;
  if (/^01[16789]/.test(digits) && (digits.length === 10 || digits.length === 11)) {
    return digits;
  }
  return null;
}

export function cleanTime(raw: unknown): string | null {
  const text = String(raw ?? '').trim().replace(/\s+/g, ' ');
  if (!text || text.length > 80) return null;
  return text;
}

export function cleanQuestion(raw: unknown): { ok: true; value: string | null } | { ok: false } {
  if (raw == null) return { ok: true, value: null };
  const text = String(raw).trim().replace(/\s+/g, ' ');
  if (!text) return { ok: true, value: null };
  if (text.length > 500) return { ok: false };
  return { ok: true, value: text };
}
