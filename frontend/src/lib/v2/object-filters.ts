/**
 * What a custom object's list can be filtered by. The `FILTERS` table is
 * fixed per module; an object's filters come from its own fields, so the
 * descriptor is built per request. Client-safe, like `filters.ts`.
 */
import type { Descriptor, Field } from '#lib/v2/filters.js';
import type { Spec } from '#lib/v2/saved-views.js';

type FieldDef = {
  key: string;
  label: string;
  field_type: string;
  is_active?: boolean;
  options?: { value: string; label: string }[] | Record<string, never> | null;
};

export const OBJECT_SEARCH_KEY = 'q';

/** The list parameter for one custom field. */
export const filterKey = (fieldKey: string) => `cf_${fieldKey}`;

/**
 * Assignee, tags, then one filter per active dropdown or checkbox. Text,
 * number, date and link fields give none: a typed filter on them is not a
 * pick from a short list.
 */
export function objectDescriptor(fields: FieldDef[] | null | undefined): Descriptor {
  const custom: Field[] = [];
  for (const f of fields ?? []) {
    if (f.is_active === false) continue;
    if (f.field_type === 'checkbox') {
      custom.push({ key: filterKey(f.key), label: f.label, type: 'boolean' });
    } else if (f.field_type === 'dropdown') {
      const options = Array.isArray(f.options) ? f.options : [];
      if (options.length === 0) continue;
      const labels = new Map(options.map((o) => [o.value, o.label]));
      custom.push({
        key: filterKey(f.key),
        label: f.label,
        type: 'select',
        options: options.map((o) => o.value),
        keepUnknown: true,
        labelFor: (v) => labels.get(v) ?? v
      });
    }
  }
  return {
    presets: [
      { key: 'mine', label: 'Mine', params: { assigned_to: '@me' } },
      { key: 'all', label: 'All', params: {} }
    ],
    fields: [
      { key: 'assigned_to', label: 'Assigned to', type: 'person', multi: true },
      { key: 'tags', label: 'Tag', type: 'tag', multi: true },
      ...custom
    ]
  };
}

/** The saved-view spec for the object's list: the search box plus every filter above. */
export function objectSavedViewSpec(fields: FieldDef[] | null | undefined): Spec {
  const { fields: filters } = objectDescriptor(fields);
  return {
    keys: [OBJECT_SEARCH_KEY, ...filters.map((f) => f.key)],
    multi: filters.filter((f) => f.multi).map((f) => f.key),
    // What the page's URL reader keeps, so a view's foreign value (a literal
    // `me`) is counted as dropped. A dropdown keeps a value that is no longer
    // an option (the server still matches records holding it), so it only
    // refuses what the API cannot store (a NUL, or too long).
    accepts: Object.fromEntries(
      filters.map((f) => [
        f.key,
        f.type === 'select' ? 'text' : f.type === 'boolean' ? 'boolean' : 'id'
      ])
    )
  };
}
