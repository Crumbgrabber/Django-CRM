/**
 * Put a rendered saved reply into the composer at the caret, replacing any
 * selection, the way the phone does (`_pickMacro` in the mobile ticket
 * screen). Only the text box changes; sending is still the ordinary reply.
 *
 * A caret the browser did not report (null) means the end of the text.
 *
 * @param text what the box holds now
 * @param start selection start
 * @param end selection end
 * @param insert the rendered reply
 */
export function insertAtCaret(
  text: string,
  start: number | null,
  end: number | null,
  insert: string
): { text: string; caret: number } {
  const from = clamp(start ?? text.length, text.length);
  const to = Math.max(from, clamp(end ?? from, text.length));
  return { text: text.slice(0, from) + insert + text.slice(to), caret: from + insert.length };
}

function clamp(n: number, max: number) {
  return Math.min(Math.max(0, n), max);
}
