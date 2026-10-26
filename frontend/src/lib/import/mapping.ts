/**
 * The column-matching step of a spreadsheet import, as plain functions.
 *
 * `ImportFlow.svelte` renders these; they stay free of Svelte and `$app/*` so
 * vitest can run them. The shapes are the server's preview reply
 * (`common/import_mapping.py`): a column is `{ index, header, field, samples }`
 * with `field` a field name or null ("Don't import"), and a skipped row is
 * `{ row, field, message, cells, kind }`, where `kind` is `duplicate` (the
 * record is already in the org, or earlier in the file) or `row` (the row
 * cannot become a record). The helpers read `kind`; `message` is for people.
 */
import { csvCell } from '#lib/utils/csv.js';

export type Column = { index: number; header?: string; field: string | null; samples?: string[] };
export type Skipped = {
  row: number;
  field: string;
  message: string;
  cells: string[];
  kind: 'duplicate' | 'row';
};
export type Field = { name: string; label: string; required?: boolean };

const NAME_FIELDS = new Set(['first_name', 'last_name']);

/**
 * Put `field` on the column at `index`. A field goes to one column only, so a
 * column that already held it is set to "Don't import" (null).
 *
 * @returns a new array; `columns` is not changed
 */
export function setColumnField<T extends Column>(
  columns: T[],
  index: number,
  field: string | null
): T[] {
  return columns.map((c) => {
    if (c.index === index) return { ...c, field };
    if (field && c.field === field) return { ...c, field: null };
    return c;
  });
}

/** The `mapping` form field for an explicit choice: `{"<index>": field | null}`. */
export function mappingPayload(columns: Column[]) {
  return JSON.stringify(Object.fromEntries(columns.map((c) => [String(c.index), c.field ?? null])));
}

/**
 * Whether any column is matched to a field. False usually means the first row
 * of the sheet is a title rather than the column names.
 */
export function hasAnyMatch(columns: Column[]) {
  return columns.some((c) => Boolean(c.field));
}

/** One sentence per dropped field, named by its label. */
export function droppedLines(dropped: { field: string; count: number }[], fields: Field[]) {
  const labels = new Map(fields.map((f) => [f.name, f.label]));
  return dropped.map(({ field, count }) => {
    const label = labels.get(field) ?? field;
    return count === 1
      ? `${label}: 1 value we couldn't use was left blank.`
      : `${label}: ${count} values we couldn't use were left blank.`;
  });
}

function rows(n: number) {
  return `${n} ${n === 1 ? 'row' : 'rows'}`;
}

/**
 * The sentence above the Import button: what importing this file will do.
 *
 * @param nouns the org's words for the record
 */
export function summaryLine(
  nouns: { singular: string; plural: string },
  preview: { skipped: Skipped[]; summary: { total: number; valid: number; skipped: number } }
) {
  const { total, valid, skipped } = preview.summary;
  const duplicates =
    preview.skipped.length > 0 && preview.skipped.every((s) => s.kind === 'duplicate');
  if (valid === 0) {
    if (total === 0) return 'This file has no rows to import.';
    // With nothing importable there is no earlier row to duplicate, so every
    // duplicate here is a record already in the org.
    if (duplicates) return 'Everything in this file is already in BottleCRM.';
    return 'Nothing in this file can be imported.';
  }
  const head = `${valid} ${valid === 1 ? nouns.singular : nouns.plural} will be imported`;
  if (skipped === 0) return `${head}.`;
  if (duplicates)
    return `${head}, and ${skipped} duplicate ${skipped === 1 ? 'row' : 'rows'} will be skipped.`;
  return `${head}, and ${rows(skipped)} will be skipped.`;
}

/**
 * Whether to offer importing the file as leads instead: a contact needs a
 * first and a last name, a lead needs only one. A name skipped as a duplicate
 * does not count, since importing it as a lead would duplicate the person.
 *
 * @param entityKey `contacts` or `leads`
 */
export function suggestLeads(entityKey: string, skipped: Skipped[]) {
  return (
    entityKey === 'contacts' && skipped.some((s) => s.kind === 'row' && NAME_FIELDS.has(s.field))
  );
}

/**
 * The skipped rows as a CSV the user can fix and upload again: the file's own
 * headers and cells, plus a `Reason` column. Short rows are padded so the
 * reason always lands under `Reason`. Every cell goes through `csvCell`, so a
 * cell that would run as a formula is neutralised.
 */
export function skippedRowsCsv(headers: string[], skipped: Skipped[]) {
  const width = skipped.reduce((w, s) => Math.max(w, s.cells.length), headers.length);
  const pad = (cells: string[]) => Array.from({ length: width }, (_, i) => cells[i] ?? '');
  return [[...pad(headers), 'Reason'], ...skipped.map((s) => [...pad(s.cells), s.message])]
    .map((cells) => cells.map(csvCell).join(','))
    .join('\n');
}
