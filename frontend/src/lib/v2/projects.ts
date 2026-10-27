/**
 * Projects: labels, the budget burn, the notification sentence, and the
 * bodies the project forms send.
 *
 * Browser-safe: no server or framework imports, so pages, server modules and
 * tests share it. Every rule here is a hint for the form; the API checks each
 * one again.
 */
import { missingOptions } from '#lib/v2/pickers.js';
import { money } from '#lib/v2/format.js';
import type { FormBody } from '#lib/api-helpers.js';
import type { components } from '#lib/api-schema.js';

type Grouping = NonNullable<
  components['schemas']['InvoiceFromTimeEntriesRequestRequest']['group_by']
>;

export const PROJECT_STATUSES = ['active', 'on_hold', 'completed', 'cancelled'];

export const PROJECT_STATUS_LABEL: Record<string, string> = {
  active: 'Active',
  on_hold: 'On hold',
  completed: 'Completed',
  cancelled: 'Cancelled'
};

export const PROJECT_STATUS_TONE: Record<string, 'ink' | 'slate' | 'clay' | 'rust' | 'moss'> = {
  active: 'ink',
  on_hold: 'clay',
  completed: 'moss',
  cancelled: 'slate'
};

export const BILLING_TYPES = ['time_and_materials', 'fixed_fee', 'retainer', 'non_billable'];

export const BILLING_TYPE_LABEL: Record<string, string> = {
  time_and_materials: 'Time and materials',
  fixed_fee: 'Fixed fee',
  retainer: 'Retainer',
  non_billable: 'Non-billable'
};

/** How a bill of time groups its lines; `entry` is the API's default. */
export const BILL_GROUPINGS: { value: Grouping; label: string }[] = [
  { value: 'single', label: 'One line for everything' },
  { value: 'person', label: 'One line per person' },
  { value: 'task', label: 'One line per task' },
  { value: 'entry', label: 'One line per entry' }
];

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): boolean {
  return typeof value === 'string' && UUID.test(value);
}

/** A grouping the API takes, else its default. */
export function billGrouping(value: unknown): Grouping {
  return BILL_GROUPINGS.find((g) => g.value === value)?.value ?? 'entry';
}

/** A `YYYY-MM-DD` the form may send, else null. */
export function isoDateOrNull(value: unknown): string | null {
  return typeof value === 'string' && ISO_DATE.test(value) ? value : null;
}

/** Decimal hours as the page writes time: "40h", "12h 30m", "45m". */
export function hoursText(hours: number | string | null | undefined): string {
  const n = Number(hours ?? 0);
  if (!Number.isFinite(n) || n <= 0) return '0h';
  const minutes = Math.round(n * 60);
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (!h) return `${m}m`;
  return m ? `${h}h ${m}m` : `${h}h`;
}

/**
 * The tone for a share of a budget used: quiet below 80%, clay from 80%, rust
 * from 100%, matching the two notification levels.
 */
export function burnTone(percent: number | null | undefined): 'slate' | 'clay' | 'rust' | null {
  if (typeof percent !== 'number' || !Number.isFinite(percent)) return null;
  if (percent >= 100) return 'rust';
  if (percent >= 80) return 'clay';
  return 'slate';
}

/**
 * One budget's meter, or null without that budget (the API sends a null
 * percent then). The bar stops at full; the label carries the overrun.
 */
export function burnMeter(
  percent: number | null | undefined
): { percent: number; width: number; tone: 'slate' | 'clay' | 'rust' } | null {
  const tone = burnTone(percent);
  if (!tone) return null;
  const p = percent as number;
  return { percent: p, width: Math.max(0, Math.min(100, p)), tone };
}

/**
 * The meter a list row shows: whichever budget is nearer to running out, and
 * what it measures. Null for a project with neither budget.
 */
export function rowBurn(
  burn: { hours_percent?: number | null; amount_percent?: number | null } | null | undefined
): {
  kind: 'hours' | 'amount';
  label: string;
  percent: number;
  width: number;
  tone: 'slate' | 'clay' | 'rust';
} | null {
  const hours = burnMeter(burn?.hours_percent);
  const amount = burnMeter(burn?.amount_percent);
  const pick = hours && (!amount || hours.percent >= amount.percent) ? 'hours' : 'amount';
  const meter = pick === 'hours' ? hours : amount;
  if (!meter) return null;
  const noun = pick === 'hours' ? 'hours' : 'budget';
  return { kind: pick, label: `${meter.percent}% of ${noun}`, ...meter };
}

/**
 * The sentence for a `project.budget` notification, or null for data of the
 * wrong shape (the row then keeps its generic copy).
 */
export function budgetNotificationText(data: unknown): string | null {
  if (!data || typeof data !== 'object') return null;
  const { kind, percent, project } = data as Record<string, unknown>;
  if (kind !== 'hours' && kind !== 'amount') return null;
  if (typeof project !== 'string' || !project.trim()) return null;
  if (typeof percent !== 'number' || !Number.isFinite(percent) || percent <= 0) return null;
  const used = percent >= 100 ? 'all' : `${Math.round(percent)}%`;
  return `${project} has used ${used} of its ${kind} budget`;
}

/**
 * A money or hours field as the API takes it: a string with two places, null
 * for blank, or undefined when it is not a number of zero or more.
 */
function decimalOrNull(raw: unknown): string | null | undefined {
  const text = String(raw ?? '').trim();
  if (!text) return null;
  const n = Number(text);
  if (!Number.isFinite(n) || n < 0) return undefined;
  return n.toFixed(2);
}

const DECIMAL_LABEL = {
  budget_hours: 'Budget hours',
  budget_amount: 'Budget amount',
  hourly_rate: 'Hourly rate'
} as Record<string, string>;

/**
 * A project form's fields as `projectValues` reads them and `projectBody`
 * takes them. A key the form did not render is absent.
 */
export type ProjectValues = {
  name?: string;
  account?: string;
  deal?: string;
  status?: string;
  billing_type?: string;
  currency?: string;
  budget_hours?: string;
  budget_amount?: string;
  hourly_rate?: string;
  retainer_fee?: string;
  retainer_hours?: string;
  retainer_rollover?: boolean;
  retainer_overage_rate?: string;
  retainer_carried_hours?: string;
  start_date?: string;
  due_date?: string;
  description?: string;
  assigned_to?: string[];
  rates?: { profile: string; hourly_rate: string }[];
  custom_fields?: Record<string, string | boolean | null>;
};

/**
 * What a project form shows: a refused save's `ProjectValues`, or the stored
 * record, whose money and hours the read gives as numbers.
 */
export type ProjectFormValues = Omit<
  ProjectValues,
  | 'budget_hours'
  | 'budget_amount'
  | 'hourly_rate'
  | 'rates'
  | 'retainer_fee'
  | 'retainer_hours'
  | 'retainer_overage_rate'
  | 'retainer_carried_hours'
> & {
  retainer_fee?: string | number | null;
  retainer_hours?: string | number | null;
  retainer_overage_rate?: string | number | null;
  retainer_carried_hours?: string | number | null;
  budget_hours?: string | number | null;
  budget_amount?: string | number | null;
  hourly_rate?: string | number | null;
  rates?: { profile: string; hourly_rate: string | number | null }[];
};

/** The create or PATCH body `projectBody` builds. */
type ProjectBody = FormBody<components['schemas']['ProjectBodyRequest']>;

/**
 * The fields a project form submitted, read off its FormData. Only what the
 * form rendered is read: `assigned__rendered` and `rates__rendered` mark the
 * two lists, so a form that could not load its people sends no list rather
 * than an empty one that would clear them.
 */
export function projectValues(form: {
  get(k: string): FormDataEntryValue | null;
  getAll(k: string): FormDataEntryValue[];
  has(k: string): boolean;
}): ProjectValues {
  const values: ProjectValues = {};
  const scalars = [
    'name',
    'account',
    'deal',
    'status',
    'billing_type',
    'currency',
    'budget_hours',
    'budget_amount',
    'hourly_rate',
    'retainer_fee',
    'retainer_hours',
    'retainer_overage_rate',
    'retainer_carried_hours',
    'start_date',
    'due_date',
    'description'
  ] as const;
  for (const key of scalars) {
    if (form.has(key)) values[key] = String(form.get(key) ?? '').trim();
  }
  // Carried hours are only the admin's to change; an untouched figure is
  // stale once a month has been billed, so it is not sent back.
  if (form.has('retainer_carried_hours__loaded')) {
    const loaded = Number(String(form.get('retainer_carried_hours__loaded') ?? '').trim() || 0);
    const typed = Number(values.retainer_carried_hours?.trim() || 0);
    if (loaded === typed) delete values.retainer_carried_hours;
  }
  // An unchecked box posts nothing, so the marker is what makes false explicit.
  if (form.has('retainer__rendered')) {
    values.retainer_rollover = form.get('retainer_rollover') === 'on';
  }
  if (form.has('assigned__rendered')) {
    values.assigned_to = form
      .getAll('assigned_to')
      .map((v) => String(v))
      .filter(Boolean);
  }
  if (form.has('rates__rendered')) {
    const people = form.getAll('rate_profile').map((v) => String(v));
    const amounts = form.getAll('rate_amount').map((v) => String(v));
    values.rates = people.map((profile, i) => ({ profile, hourly_rate: amounts[i] ?? '' }));
  }
  return values;
}

/**
 * Whether the form shows Status as text and posts none: on a retainer the API
 * leaves status to admins, so a member's choice would be silently dropped.
 */
export function statusLocked(
  edit: boolean,
  isAdmin: boolean,
  billingType: string | null | undefined
): boolean {
  return edit && !isAdmin && billingType === 'retainer';
}

/**
 * The create or PATCH body for a project, and what is wrong with it.
 *
 * A key absent from `values` stays absent, so a PATCH leaves that field
 * alone; blank optional fields are sent as null. A rate row with no person is
 * dropped as an unused row; one with a person and no valid rate is an error.
 */
export function projectBody(values: ProjectValues): { body: ProjectBody; errors: string[] } {
  const body: ProjectBody = {};
  const errors: string[] = [];

  if ('name' in values) {
    body.name = String(values.name ?? '').trim();
    if (!body.name) errors.push('Give the project a name.');
  }
  if ('account' in values) {
    body.account = values.account || null;
    if (!body.account) errors.push('Pick the account this project is for.');
  }
  if ('deal' in values) body.deal = values.deal || null;
  if ('status' in values && values.status) body.status = values.status;
  if ('billing_type' in values && values.billing_type) body.billing_type = values.billing_type;
  if ('currency' in values && values.currency) body.currency = values.currency;

  for (const key of ['budget_hours', 'budget_amount', 'hourly_rate'] as const) {
    if (!(key in values)) continue;
    const parsed = decimalOrNull(values[key]);
    if (parsed === undefined) errors.push(`${DECIMAL_LABEL[key]} must be a number of 0 or more.`);
    else body[key] = parsed;
  }
  for (const key of ['start_date', 'due_date'] as const) {
    if (key in values) body[key] = isoDateOrNull(values[key]);
  }
  appendRetainer(values, body, errors);
  const start = isoDateOrNull(values.start_date);
  const due = isoDateOrNull(values.due_date);
  if (start && due && due < start) {
    errors.push('The due date cannot be before the start date.');
  }
  if ('description' in values) body.description = String(values.description ?? '');
  if ('assigned_to' in values) body.assigned_to = [...new Set(values.assigned_to ?? [])];

  if ('rates' in values) {
    const rates: { profile: string; hourly_rate: string }[] = [];
    const seen = new Set();
    for (const row of values.rates ?? []) {
      if (!row?.profile) continue;
      const rate = decimalOrNull(row.hourly_rate);
      if (!rate) {
        errors.push('Each person on the rates list needs a rate of 0 or more.');
        continue;
      }
      if (seen.has(row.profile)) {
        errors.push('A person can have only one rate on a project.');
        continue;
      }
      seen.add(row.profile);
      rates.push({ profile: row.profile, hourly_rate: rate });
    }
    body.rates = rates;
  }
  if (values.custom_fields) body.custom_fields = values.custom_fields;
  return { body, errors: [...new Set(errors)] };
}

/**
 * The retainer fields of a body. The checks run only while the billing type
 * being sent is `retainer`; other keys sent are passed on as typed.
 */
function appendRetainer(values: ProjectValues, body: ProjectBody, errors: string[]) {
  const isRetainer = values.billing_type === 'retainer';
  const parsed = (raw: string | undefined, label: string) => {
    const n = decimalOrNull(raw);
    if (n === undefined) errors.push(`${label} must be a number of 0 or more.`);
    return n ?? null;
  };
  let fee: string | null = null;
  let hours: string | null = null;
  let overage: string | null = null;
  if ('retainer_fee' in values) {
    fee = parsed(values.retainer_fee, 'Monthly fee');
    if (isRetainer && !(Number(fee) >= 0.01)) errors.push('Set the monthly fee.');
    body.retainer_fee = fee;
  }
  if ('retainer_hours' in values) {
    hours = parsed(values.retainer_hours, 'Hours included each month');
    body.retainer_hours = hours;
  }
  if ('retainer_overage_rate' in values) {
    overage = parsed(values.retainer_overage_rate, 'Rate for hours over the allowance');
    body.retainer_overage_rate = overage;
  }
  if (isRetainer && hours !== null && overage === null) {
    errors.push('Set the rate for hours over the allowance.');
  }
  if ('retainer_carried_hours' in values) {
    body.retainer_carried_hours =
      parsed(values.retainer_carried_hours, 'Carried hours') ?? (0).toFixed(2);
  }
  if ('retainer_rollover' in values) body.retainer_rollover = values.retainer_rollover === true;
}

/** An id, or the `{ id, name }` a read expands it to. */
type RefOrId = string | { id?: string | null; name?: string | null } | null | undefined;

/**
 * The new-project form's values from a `from-deal` draft. Unknown or missing
 * keys fall back to the form's defaults.
 */
export function draftValues(
  draft:
    | {
        name?: string | null;
        account?: RefOrId;
        deal?: RefOrId;
        currency?: string | null;
        assigned_to?: RefOrId[] | null;
        billing_type?: string | null;
        budget_amount?: string | null;
      }
    | false
    | null
    | undefined
): {
  name?: string;
  account?: string;
  deal?: string;
  currency?: string;
  assigned_to?: string[];
  billing_type?: string;
  budget_amount?: string;
} {
  if (!draft || typeof draft !== 'object') return {};
  const id = (v: RefOrId) => (v && typeof v === 'object' ? (v.id ?? '') : (v ?? ''));
  return {
    name: draft.name ?? '',
    account: id(draft.account),
    deal: id(draft.deal),
    currency: draft.currency ?? '',
    assigned_to: Array.isArray(draft.assigned_to) ? draft.assigned_to.map(id).filter(Boolean) : [],
    billing_type:
      draft.billing_type && BILLING_TYPES.includes(draft.billing_type) ? draft.billing_type : '',
    budget_amount: draft.budget_amount ?? ''
  };
}

/**
 * The body for `invoice-amount/`: exactly one of an amount or a percentage
 * of the fee, and an optional line description.
 *
 * @param budgetAmount the project's fee, for a percentage
 */
export function invoiceAmountBody(
  { mode, value, description }: { mode?: string; value?: string; description?: string },
  budgetAmount: number | null
): { body?: components['schemas']['InvoiceAmountRequest']; error?: string } {
  const n = Number(String(value ?? '').trim());
  const body: components['schemas']['InvoiceAmountRequest'] = {};
  if (mode === 'percent') {
    if (budgetAmount === null || !(budgetAmount > 0)) {
      return { error: 'Set a budget amount on the project before invoicing a percentage of it.' };
    }
    if (!Number.isFinite(n) || n <= 0 || n > 100) {
      return { error: 'The percentage must be more than 0 and at most 100.' };
    }
    body.percent = String(Math.round(n * 100) / 100);
  } else if (mode === 'amount') {
    if (!Number.isFinite(n) || n <= 0) return { error: 'The amount must be more than 0.' };
    body.amount = n.toFixed(2);
  } else {
    return { error: 'Choose an amount or a percentage of the fee.' };
  }
  const text = String(description ?? '').trim();
  if (text) body.description = text;
  return { body };
}

/**
 * The project a task hangs off, as the task pages link to it. The read gives
 * an id, or `{ id, name }` where a list expands it.
 */
export function taskProject(value: unknown): { id: string; name: string } | null {
  if (!value) return null;
  if (typeof value === 'string') return { id: value, name: '' };
  const v = value as { id?: unknown; name?: unknown };
  if (typeof value === 'object' && typeof v.id === 'string') {
    return { id: v.id, name: typeof v.name === 'string' ? v.name : '' };
  }
  return null;
}

/**
 * The Bill time line for entries that will bill at 0 for want of a rate, or
 * '' when every entry has one.
 */
export function unratedText(unrated: number | null | undefined): string {
  const n = Number(unrated) || 0;
  if (n <= 0) return '';
  if (n === 1) return '1 entry has no rate and will be billed at 0.';
  return `${n} of these entries have no rate and will be billed at 0.`;
}

/**
 * Where the Bill time form posts: the `billTime` action, with the panel's own
 * query kept, so a refusal without JavaScript reopens the panel showing why.
 *
 * @param upTo YYYY-MM-DD
 */
export function billActionUrl(upTo: string): string {
  const query = new URLSearchParams({ bill: '1' });
  const date = isoDateOrNull(upTo);
  if (date) query.set('up_to', date);
  return `?${query}&/billTime`;
}

/**
 * A project picker's options with the one already chosen kept, first, when it
 * is not among those listed (the picker lists the first 200), so a form
 * neither clears it nor asks for it again.
 */
export function projectOptions(
  choices: { id: string; name: string }[],
  current: { id: string; name: string } | null | undefined
): { id: string; name: string }[] {
  return [...missingOptions(choices, current ? [current] : []), ...choices];
}

/**
 * Whether time on a project starts out billable: yes unless the project is
 * non-billable, where the API keeps every entry non-billable.
 */
export function defaultBillable(billingType: string | null | undefined): boolean {
  return billingType !== 'non_billable';
}

const MONTH_NAMES = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December'
];

/** "October 2026" from `YYYY-MM` or `YYYY-MM-DD`, else ''. Never goes through a Date, so no zone shifts it. */
export function monthLabel(value: unknown): string {
  const m = typeof value === 'string' ? value.match(/^(\d{4})-(\d{2})(?:-\d{2})?$/) : null;
  const name = m ? MONTH_NAMES[Number(m[2]) - 1] : undefined;
  return m && name ? `${name} ${m[1]}` : '';
}

/** Hours as a plain number for a sentence: "12", "12.5", "0.25". */
function hoursFigure(hours: unknown): string {
  const n = Number(hours);
  return Number.isFinite(n) ? String(Math.round(n * 100) / 100) : '0';
}

const hoursNoun = (hours: unknown) => (hoursFigure(hours) === '1' ? 'hour' : 'hours');

/** What the API's `retainer_usage` holds, numbers already read. */
export type RetainerUsage = {
  month: string;
  used_hours: number;
  available_hours: number | null;
  overage_hours: number;
  billable_now: boolean;
};

/**
 * The Retainer panel's sentences. A line is null when it has nothing to say;
 * `usage` is null until the API sends a month to describe.
 */
export function retainerPanel(p: {
  retainer_fee: number | null;
  retainer_overage_rate: number | null;
  retainer_carried_hours: number | null;
  retainer_last_month: string | null;
  currency: string;
  usage: RetainerUsage | null;
}): {
  fee: string;
  usage: string | null;
  overage: string | null;
  carried: string | null;
  ended: string | null;
} {
  const u = p.usage;
  const month = monthLabel(u?.month);
  let usage: string | null = null;
  if (u && month) {
    usage =
      u.available_hours === null
        ? `${hoursFigure(u.used_hours)} ${hoursNoun(u.used_hours)} in ${month}`
        : `${hoursFigure(u.used_hours)} of ${hoursFigure(u.available_hours)} hours used in ${month}`;
  }
  let overage: string | null = null;
  if (u && u.overage_hours > 0) {
    const amount =
      p.retainer_overage_rate === null
        ? ''
        : `, ${money(Math.round(u.overage_hours * p.retainer_overage_rate * 100) / 100, p.currency)}`;
    overage = `${hoursFigure(u.overage_hours)} ${hoursNoun(u.overage_hours)} over the allowance so far${amount}`;
  }
  const carriedHours = p.retainer_carried_hours ?? 0;
  const ended = monthLabel(p.retainer_last_month);
  return {
    fee:
      p.retainer_fee === null
        ? 'No monthly fee set'
        : `${money(p.retainer_fee, p.currency)} a month`,
    usage,
    overage,
    carried:
      carriedHours > 0
        ? `${hoursFigure(carriedHours)} ${hoursNoun(carriedHours)} carried in from earlier months`
        : null,
    ended: ended ? `Ended after ${ended}` : null
  };
}

/**
 * The sentence for a `project.retainer_invoice` notification, or null for
 * data of the wrong shape (the row then keeps its generic copy).
 */
export function retainerInvoiceNotificationText(data: unknown): string | null {
  if (!data || typeof data !== 'object') return null;
  const { project, month, invoice_number } = data as Record<string, unknown>;
  const label = monthLabel(month);
  if (typeof project !== 'string' || !project.trim()) return null;
  if (typeof invoice_number !== 'string' || !invoice_number.trim() || !label) return null;
  return `Retainer invoice ${invoice_number} for ${label} drafted for ${project}`;
}
