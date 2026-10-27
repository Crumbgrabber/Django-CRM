/**
 * Field rendering and form collection shared by every record page that shows
 * or edits per-org custom fields. Imports only browser-safe helpers, so it is
 * unit tested in Node.
 */
import { longDate } from '#lib/v2/format.js';
import { sameIds } from '#lib/v2/pickers.js';

type FieldOption = { value: string; label: string };

/**
 * A field definition as these helpers read it: an org's custom field
 * (`CustomFieldDefinition`) or a custom object's field. A non-dropdown may
 * store `{}` as its options.
 */
export type FieldDefinition = {
  key: string;
  label: string;
  field_type: string;
  options?: FieldOption[] | Record<string, never> | null;
  is_required?: boolean;
};

const optionsOf = (definition: FieldDefinition) =>
  Array.isArray(definition.options) ? definition.options : [];

/**
 * Render one stored value for reading.
 *
 * Values arrive already coerced by `_coerce_value`: number as a JSON number,
 * checkbox as a real boolean, date as a YYYY-MM-DD string, so this formats
 * rather than parses. A dropdown stores its `value`; the human-facing `label`
 * lives on the definition, so it is looked up here instead of showing the raw
 * key.
 */
export function displayValue(definition: FieldDefinition, value: unknown): string {
  if (value === null || value === undefined || value === '') return '';

  switch (definition.field_type) {
    case 'checkbox':
      return value ? 'Yes' : 'No';
    case 'date': {
      const text = longDate(value as string);
      return text === '—' ? String(value) : text;
    }
    case 'number':
      return typeof value === 'number' ? value.toLocaleString() : String(value);
    case 'dropdown': {
      const match = optionsOf(definition).find((o) => o.value === value);
      return match?.label ?? String(value);
    }
    default:
      return String(value);
  }
}

/**
 * Pair definitions with a record's stored values for the detail page.
 *
 * Every active definition appears, including the ones this record has no value
 * for. A blank "Possession by" is information, and a list that silently omits
 * unfilled fields hides what the org decided it tracks. `filled` lets the page
 * decide whether the block is worth showing at all.
 */
export function pairForDisplay(
  definitions: FieldDefinition[],
  values: Record<string, unknown> | null | undefined
) {
  const stored = values ?? {};
  return definitions.map((d) => {
    const raw = stored[d.key];
    return {
      key: d.key,
      label: d.label,
      field_type: d.field_type,
      value: displayValue(d, raw),
      filled: raw !== null && raw !== undefined && raw !== ''
    };
  });
}

/**
 * Shape the definitions and current values for the edit form.
 *
 * A checkbox is normalised to a real boolean and everything else to a string,
 * because that is what the inputs bind to. `''` for an unset field means the
 * input renders empty and submits empty, which `_coerce_value` maps back to
 * `None`, so clearing a field works without a separate "remove" control.
 */
export function pairForEdit(
  definitions: FieldDefinition[],
  values: Record<string, unknown> | null | undefined
) {
  const stored = values ?? {};
  return definitions.map((d) => {
    const raw = stored[d.key];
    let options = optionsOf(d);
    // A select with no option for the stored value submits nothing and clears it.
    if (
      d.field_type === 'dropdown' &&
      raw !== null &&
      raw !== undefined &&
      raw !== '' &&
      !options.some((o) => o.value === raw)
    ) {
      // A dropdown's stored value is the option's string `value`.
      const value = raw as string;
      options = [...options, { value, label: `${value} (no longer an option)` }];
    }
    return {
      key: d.key,
      label: d.label,
      field_type: d.field_type,
      options,
      is_required: d.is_required ?? false,
      value:
        d.field_type === 'checkbox'
          ? Boolean(raw)
          : raw === null || raw === undefined
            ? ''
            : String(raw)
    };
  });
}

/**
 * Collect `cf_<key>` inputs off a submitted form into a custom_fields object.
 *
 * Driven by the definition list, not by what the body happens to carry: a key
 * with no active definition is never read, and an unchecked checkbox, which
 * submits nothing at all in HTML. Becomes an explicit `false` rather than
 * silently keeping its previous value. Without that, a checkbox could be
 * ticked but never unticked.
 */
export function collectFromForm(
  form: FormData,
  definitions: FieldDefinition[]
): Record<string, string | boolean | null> {
  const out: Record<string, string | boolean | null> = {};
  for (const d of definitions) {
    const field = `cf_${d.key}`;
    if (d.field_type === 'checkbox') {
      out[d.key] = form.get(field) !== null;
      continue;
    }
    if (!form.has(field)) continue;
    const raw = form.get(field)?.toString().trim() ?? '';
    out[d.key] = raw === '' ? null : raw;
  }
  return out;
}

/**
 * Link fields of a `Field` list, paired with the record's `links` answer.
 * A one-record field held by a link the caller cannot open is read-only: the
 * server refuses a write to it, so the form shows no input.
 */
export function linkFieldsForEdit(
  fields: Array<FieldDefinition & { target?: string | null; many?: boolean | null }>,
  links:
    Record<string, { records?: { id: string; name: string }[]; hidden?: number }> | null | undefined
) {
  const held = links ?? {};
  return fields
    .filter((f) => f.field_type === 'link')
    .map((f) => {
      const entry = held[f.key] ?? {};
      const many = Boolean(f.many);
      const hidden = entry.hidden ?? 0;
      return {
        key: f.key,
        label: f.label,
        target: f.target,
        many,
        records: entry.records ?? [],
        hidden,
        readOnly: !many && hidden > 0
      };
    });
}

/** @param was Comma-joined ids the page showed. */
const differs = (ids: string[], was: string) =>
  !sameIds(ids.filter(Boolean), was.split(',').filter(Boolean));

/**
 * Link ids to send, keyed by field, only for fields whose ids changed since
 * the page rendered. A field without a `link_<key>__was` input (read-only) is
 * never sent.
 */
export function collectLinks(
  form: FormData,
  linkFields: { key: string }[]
): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const { key } of linkFields) {
    const was = form.get(`link_${key}__was`);
    if (was === null) continue;
    const ids = form.getAll(`link_${key}`).map(String);
    if (differs(ids, String(was))) out[key] = ids.filter(Boolean);
  }
  return out;
}

/**
 * Assignee ids to send, or `undefined` when they are unchanged. A form with no
 * `assigned_to__was` (a create form) always sends what was picked.
 */
export function collectAssignees(form: FormData): string[] | undefined {
  const ids = form.getAll('assigned_to').map(String);
  const was = form.get('assigned_to__was');
  if (was === null) return ids;
  return differs(ids, String(was)) ? ids : undefined;
}

/**
 * The tag ids to send: undefined when the form drew no picker (no
 * `tags__was`) or the set is as the page showed it, else the chosen ids, which
 * may be none. An unchanged set is noise, and leaving it out keeps tags a concurrent edit added.
 */
export function collectTags(form: FormData): string[] | undefined {
  const was = form.get('tags__was');
  if (was === null) return undefined;
  const ids = form.getAll('tags').map(String).filter(Boolean);
  return differs(ids, String(was)) ? ids : undefined;
}
