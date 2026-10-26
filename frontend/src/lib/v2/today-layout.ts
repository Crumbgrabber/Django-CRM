/**
 * What the Today page shows around its queue.
 *
 * The import card depends on the workspace alone, never on the queue. A new
 * workspace that chose a starter pack already has overdue sample tasks, and
 * a card that waited for an empty queue never reached the people it is for.
 * The phone's dashboard shows it on the same condition, at the top.
 *
 * `tail` is the line under the queue: `everything` when the queue holds all
 * that is due, `more` when some was left out (`hidden` of it), `clear` for an
 * empty queue, and null for an empty queue under the import card, which
 * already says what to do next.
 *
 * @param queued how many items the queue shows
 */
export function todayLayout(
  summary: { empty_workspace?: boolean; can_import?: boolean; count: number; shown: number },
  queued: number
): { importCard: boolean; hidden: number; tail: 'everything' | 'more' | 'clear' | null } {
  const importCard = Boolean(summary.empty_workspace && summary.can_import);
  const hidden = Math.max(0, summary.count - summary.shown);
  let tail: 'everything' | 'more' | 'clear' | null = null;
  if (queued) tail = hidden === 0 ? 'everything' : 'more';
  else if (!importCard) tail = 'clear';
  return { importCard, hidden, tail };
}
