/**
 * What `ImportFlow` needs to know about each importable record.
 *
 * - `singular`, `plural`: default words for the record; the leads drawer
 *   passes the org's own terminology instead.
 * - `actionPath`: the list page whose form actions (`?/importPreview`,
 *   `?/importCommit`) forward the upload to Django, so the flow works from any
 *   page, not only from that list.
 * - `listHref`: where the imported records are listed.
 * - `templateHeaders`, `templateExample`: the downloadable template, one
 *   header row and one example row. The headers are the importer's own field
 *   names, so a filled-in template matches itself.
 */
export type ImportConfig = {
  singular: string;
  plural: string;
  actionPath: string;
  listHref: string;
  templateHeaders: string[];
  templateExample: string[];
  /** Names the template and skipped-rows downloads; the entity key when absent. */
  fileStem?: string;
};

export const IMPORT_ENTITIES = {
  contacts: {
    singular: 'contact',
    plural: 'contacts',
    actionPath: '/contacts',
    listHref: '/contacts',
    templateHeaders: [
      'first_name',
      'last_name',
      'email',
      'phone',
      'organization',
      'title',
      'department',
      'do_not_call',
      'linkedin_url',
      'address_line',
      'city',
      'state',
      'postcode',
      'country',
      'description',
      'account_name',
      'assigned_emails',
      'team_names',
      'tags'
    ],
    templateExample: [
      'Alice',
      'Smith',
      'alice@acme.test',
      '+1 (555) 123-4567',
      'Acme Corp',
      'VP of Sales',
      'Sales',
      'no',
      'https://linkedin.com/in/alice',
      '500 Main St',
      'Austin',
      'TX',
      '78701',
      'US',
      'Met at SaaStr 2024',
      'Acme Corp',
      'agent@yourco.com',
      'Sales',
      'vip;newsletter'
    ]
  },
  leads: {
    singular: 'lead',
    plural: 'leads',
    actionPath: '/leads',
    listHref: '/leads',
    templateHeaders: [
      'first_name',
      'last_name',
      'email',
      'phone',
      'title',
      'company_name',
      'job_title',
      'status',
      'source',
      'rating',
      'opportunity_amount',
      'close_date',
      'description',
      'assigned_emails',
      'team_names',
      'tags'
    ],
    templateExample: [
      'Alice',
      'Smith',
      'alice@acme.test',
      '+1 (555) 123-4567',
      'Enterprise rollout',
      'Acme Corp',
      'VP of Sales',
      'assigned',
      'email',
      'HOT',
      '12000',
      '2026-12-31',
      'Met at SaaStr',
      'agent@yourco.com',
      'Sales',
      'vip;trade-show'
    ]
  }
};

type ObjectDef = {
  key: string;
  label: string;
  label_plural: string;
  name_label: string;
  fields?: {
    key: string;
    label: string;
    field_type: string;
    is_active?: boolean;
    options?: { value: string; label: string }[] | Record<string, never> | null;
  }[];
};

/** Field keys the server never maps (they would collide with a built-in column). */
const RESERVED_KEYS = ['name', 'assigned_to', 'tags', 'full_name'];

/**
 * What a custom object's rows can be imported into, in the order of the
 * template: the name, each active field (link fields are matched by the
 * server from the preview, not filled from a spreadsheet), then the people
 * and tags, which are named by email and tag name.
 */
export function objectImportTargets(def: ObjectDef): { name: string; label: string }[] {
  return [
    { name: 'name', label: def.name_label },
    ...(def.fields ?? [])
      .filter(
        (f) => f.is_active !== false && f.field_type !== 'link' && !RESERVED_KEYS.includes(f.key)
      )
      .map((f) => ({ name: f.key, label: f.label })),
    { name: 'assigned_to', label: 'Assigned to' },
    { name: 'tags', label: 'Tags' }
  ];
}

const EXAMPLE_BY_TYPE: Record<string, string> = {
  number: '3',
  date: '2026-12-31',
  checkbox: 'Yes',
  textarea: 'A longer note'
};

/**
 * The import dialog's settings for one custom object. Its form actions live on
 * the object's own list page.
 */
export function objectImportConfig(def: ObjectDef): ImportConfig {
  const fields = new Map((def.fields ?? []).map((f) => [f.key, f]));
  const targets = objectImportTargets(def);
  const example = (name: string) => {
    if (name === 'name') return `Example ${def.label.toLowerCase()}`;
    if (name === 'assigned_to') return 'agent@yourco.com';
    if (name === 'tags') return 'vip,featured';
    const field = fields.get(name);
    if (field?.field_type === 'dropdown' && Array.isArray(field.options) && field.options[0]) {
      return field.options[0].label;
    }
    return EXAMPLE_BY_TYPE[field?.field_type ?? ''] ?? 'Example';
  };
  return {
    singular: def.label.toLowerCase(),
    plural: def.label_plural.toLowerCase(),
    actionPath: `/objects/${def.key}`,
    listHref: `/objects/${def.key}`,
    templateHeaders: targets.map((t) => t.label),
    templateExample: targets.map((t) => example(t.name)),
    fileStem: def.key
  };
}
