/**
 * Per-org custom fields on the built-in records, for every target the API
 * extends (`Lead`, `Contact`, `Account`, `Opportunity`, `Case`, `Task`,
 * `Invoice`, `Estimate`, `RecurringInvoice`).
 *
 * New pages read the definitions here. Detail and edit pages read the
 * `custom_field_definitions` their detail response already carries, so they
 * make no extra call. The API's `validate_payload` is the authority on every
 * write: it drops keys with no active definition and coerces each value.
 */
import { apiRequest } from '#lib/api-helpers.js';
import { apiErrorBody } from '#lib/api-errors.js';
import {
  collectFromForm,
  pairForDisplay,
  pairForEdit,
  type FieldDefinition
} from '#lib/server/v2/record-fields.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];
type DefinitionRow = Schemas['CustomFieldDefinitionRow'];
type Definition = FieldDefinition & { display_order?: number };

/**
 * Active definitions for one target, in display order. A failure answers []:
 * the fields are an addition to the page, not a reason to lose it.
 *
 * @param target the API's `target_model`, such as `Contact`
 */
export async function fieldDefinitions(cookies: Cookies, target: string): Promise<DefinitionRow[]> {
  try {
    return await loadDefinitions(cookies, target);
  } catch {
    return [];
  }
}

/** Like `fieldDefinitions`, but a failed read throws. */
async function loadDefinitions(cookies: Cookies, target: string) {
  // Without include_counts=false the endpoint counts missing values per field over the whole table.
  const response: Schemas['CustomFieldDefinitionListResponse'] = await apiRequest(
    `/custom-fields/?target_model=${encodeURIComponent(target)}&active_only=true&include_counts=false`,
    {},
    { cookies }
  );
  return sortDefinitions(response?.definitions ?? []);
}

function sortDefinitions<D extends { display_order?: number; label?: string }>(
  definitions: D[]
): D[] {
  return [...definitions].sort(
    (a, b) =>
      (a.display_order ?? 0) - (b.display_order ?? 0) ||
      String(a.label ?? '').localeCompare(String(b.label ?? ''))
  );
}

/** A New page's empty inputs. */
export async function fieldsForNew(cookies: Cookies, target: string) {
  return pairForEdit(await fieldDefinitions(cookies, target), {});
}

/**
 * A record's `custom_fields` (a JSON field, so `unknown` in the schema) as the
 * key-to-value object it is, or null.
 */
const asRecord = (values: unknown) =>
  values && typeof values === 'object' && !Array.isArray(values)
    ? (values as Record<string, unknown>)
    : null;

/**
 * The detail page's block: every active field, filled or not. Empty when the
 * org has no active fields for this record type, so the page shows no block;
 * a value kept under a turned-off field has no definition in the response to
 * label it, and stays hidden as the admin chose.
 *
 * @param response the detail response
 * @param values the record's `custom_fields`
 */
export function fieldsForDetail(
  response: { custom_field_definitions?: Definition[] } | null | undefined,
  values: unknown
) {
  return pairForDisplay(
    sortDefinitions(response?.custom_field_definitions ?? []),
    asRecord(values)
  );
}

/** The edit page's inputs, from the same detail response. */
export function fieldsForEdit(
  response: { custom_field_definitions?: Definition[] } | null | undefined,
  values: unknown
) {
  return pairForEdit(sortDefinitions(response?.custom_field_definitions ?? []), asRecord(values));
}

export const FIELDS_UNREADABLE =
  'The custom fields could not be read just now, so nothing was saved. Try again in a moment.';

/**
 * The `custom_fields` to send, read off a submitted form: only the fields the
 * form rendered (`cf__rendered`), typed by the org's current definitions. A
 * form that rendered none sends no key at all, so its body is unchanged.
 *
 * When the form rendered fields but the definitions cannot be read now, there
 * is nothing to type them by, and sending nothing would drop what the person
 * entered while the save reports success. `refusal` is then set, and the
 * action returns it through `fail()` instead of saving.
 */
export async function readCustomFields(
  cookies: Cookies,
  target: string,
  form: FormData
): Promise<{
  values: Record<string, string | boolean | null> | undefined;
  definitions: DefinitionRow[];
  refusal?: { error: string; fieldErrors: Record<string, string> };
}> {
  const rendered = new Set((form.get('cf__rendered')?.toString() ?? '').split(',').filter(Boolean));
  if (rendered.size === 0) return { values: undefined, definitions: [] };
  let all: DefinitionRow[];
  try {
    all = await loadDefinitions(cookies, target);
  } catch {
    return {
      values: undefined,
      definitions: [],
      refusal: { error: FIELDS_UNREADABLE, fieldErrors: {} }
    };
  }
  const definitions = all.filter((d) => rendered.has(d.key));
  if (definitions.length === 0) return { values: undefined, definitions };
  return { values: collectFromForm(form, definitions), definitions };
}

/**
 * A refused save as the form shows it: per-field messages from
 * `errors.custom_fields.<key>`, placed beside their inputs, and one sentence
 * for the top of the form.
 *
 * @param err the error `apiRequest` threw
 * @param definitions labels for the messages
 */
export function saveRefusal(
  err: unknown,
  definitions: { key: string; label: string }[],
  fallback: string
): { error: string; fieldErrors: Record<string, string> } {
  const errors = apiErrorBody(err)?.errors;
  const raw =
    errors && typeof errors === 'object'
      ? (errors as { custom_fields?: unknown }).custom_fields
      : undefined;
  const fieldErrors: Record<string, string> = {};
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    for (const [key, detail] of Object.entries(raw)) {
      const text = Array.isArray(detail) ? detail.join(' ') : String(detail);
      const label = definitions.find((d) => d.key === key)?.label ?? key;
      fieldErrors[key] = `${label} ${text}.`;
    }
  }
  const messages = Object.values(fieldErrors);
  if (messages.length > 0) return { error: messages.join(' '), fieldErrors };
  if (typeof raw === 'string') return { error: `Custom fields ${raw}.`, fieldErrors };
  return { error: readableError(err, fallback), fieldErrors };
}
