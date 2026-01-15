const te = new TextEncoder();

export function stableStringify(value: unknown): string {
  return JSON.stringify(sortValue(value));
}

function sortValue(v: any): any {
  if (v == null) return null;
  if (Array.isArray(v)) {
    // NOTE: arrays are kept in original order by default.
    // Callers should sort arrays when the semantics are set-like (e.g., filters).
    return v.map(sortValue);
  }
  if (typeof v === 'object') {
    const out: Record<string, any> = {};
    for (const k of Object.keys(v).sort()) out[k] = sortValue(v[k]);
    return out;
  }
  return v;
}

export async function sha256Hex(input: string): Promise<string> {
  const buf = te.encode(input);
  const hash = await crypto.subtle.digest('SHA-256', buf);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

