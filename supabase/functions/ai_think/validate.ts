import type { AttachmentRef } from './context.ts';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const ALLOWED_ATTACHMENT_MIME = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'application/pdf']);
export const MAX_MESSAGE_CHARS = 20000;
export const MAX_ATTACHMENTS = 6;
export const MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024;

export function uuidOrNull(v: unknown): string | null {
  return typeof v === 'string' && UUID_RE.test(v.trim()) ? v.trim() : null;
}

/** 첨부는 요청한 사용자 폴더(`{userId}/...`)에 올라간 파일만 받는다. 실패하면 오류 코드 문자열. */
export function parseAttachments(raw: unknown, userId: string): AttachmentRef[] | string {
  if (raw == null) return [];
  if (!Array.isArray(raw)) return 'attachments_invalid';
  if (raw.length > MAX_ATTACHMENTS) return 'attachments_too_many';
  const out: AttachmentRef[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') return 'attachments_invalid';
    const a = item as Record<string, unknown>;
    const path = typeof a.path === 'string' ? a.path.trim() : '';
    const name = typeof a.name === 'string' ? a.name.trim().slice(0, 200) : '';
    const mime = typeof a.mime === 'string' ? a.mime.trim().toLowerCase() : '';
    const size = typeof a.size === 'number' ? a.size : null;
    if (!path || path.length > 500 || path.includes('..') || !path.startsWith(`${userId}/`)) return 'attachment_path_invalid';
    if (!ALLOWED_ATTACHMENT_MIME.has(mime)) return 'attachment_type_invalid';
    if (size !== null && (size < 0 || size > MAX_ATTACHMENT_BYTES)) return 'attachment_too_large';
    out.push({ path, name: name || path.split('/').pop() || 'file', mime, size });
  }
  return out;
}
