/**
 * How the merge page names one of its two records.
 *
 * Duplicates usually share a name, and "merge Rosalind Beck into Rosalind
 * Beck" tells nobody which one survives. When the names are equal the two are
 * "this record" (the page the merge was opened from) and "the other record".
 * The phone's compare screen says the same.
 *
 * @param current the record the page was opened from
 */
export function mergeSideLabel(
  side: { id: string; name: string },
  current: { id: string; name: string },
  other: { id: string; name: string }
) {
  if (current.name !== other.name) return side.name;
  return side.id === current.id ? 'this record' : 'the other record';
}
