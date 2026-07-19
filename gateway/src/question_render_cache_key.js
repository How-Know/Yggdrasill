import { createHash } from 'node:crypto';

export function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

export function hashQuestionContent(
  question,
  renderProfile,
  rendererVersion,
  namespace = '',
) {
  const content = {
    stem: String(question?.stem || ''),
    choices: Array.isArray(question?.choices) ? question.choices : [],
    figure_refs: Array.isArray(question?.figure_refs)
      ? question.figure_refs
      : [],
    meta:
      question?.meta && typeof question.meta === 'object'
        ? question.meta
        : {},
  };
  const contentHash = createHash('sha256')
    .update(JSON.stringify(canonicalize(content)))
    .digest('hex');
  const cacheKey = createHash('sha256')
    .update(
      JSON.stringify(
        canonicalize({
          content_hash: contentHash,
          namespace: String(namespace || ''),
          render_profile: renderProfile,
          renderer_version: rendererVersion,
        }),
      ),
    )
    .digest('hex');
  return { contentHash, cacheKey };
}
