/**
 * The usage columns on Settings > Tags. The server names every record kind a
 * tag can sit on (`usage_labels`, keyed like each tag's `usage` map), so a
 * custom object gets a column without a client release. Client-safe.
 */

/**
 * The words used for a usage key when the API sends no `usage_labels` (a
 * server from before the release window): the phone's, so both apps agree.
 */
const FALLBACK_WORDS: Record<string, string> = {
  opportunities: 'deals',
  cases: 'tickets',
  api_settings: 'API keys'
};

function fallbackLabel(key: string): string {
  const word = FALLBACK_WORDS[key] ?? key.replaceAll('_', ' ');
  return word.charAt(0).toUpperCase() + word.slice(1);
}

export type UsageColumn = { key: string; label: string };

/**
 * One column per usage key: the server's labelled keys in its order, then any
 * key a tag carries that it did not label (shown under the fallback words
 * above, which is also all an API without `usage_labels` gets).
 */
export function usageColumns(
  usageLabels: Record<string, string> | null | undefined,
  tags: { usage?: Record<string, number> }[]
): UsageColumn[] {
  const labels = usageLabels ?? {};
  const keys = Object.keys(labels);
  for (const tag of tags) {
    for (const key of Object.keys(tag.usage ?? {})) {
      if (!keys.includes(key)) keys.push(key);
    }
  }
  return keys.map((key) => ({ key, label: labels[key] ?? fallbackLabel(key) }));
}
