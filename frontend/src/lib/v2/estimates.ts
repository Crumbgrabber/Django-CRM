/**
 * Estimates as proposals: the deposit preview, the proposal fields the
 * builder sends, and the sentences the portal, the worklist and
 * notifications show.
 *
 * Browser-safe: no server or framework imports, so pages, server modules and
 * tests share it. The API computes the deposit and checks every field again.
 */
import { money } from '#lib/v2/format.js';
import { divHalfUp, hundredths, num, type Figure } from '#lib/v2/line-items.js';

export const INTRODUCTION_MAX = 5000;

/** What a project started from an estimate is billed as, in the builder's order. */
export const PROJECT_BILLING_TYPES = ['fixed_fee', 'time_and_materials', 'non_billable'];

const isSet = (v: Figure) => v !== null && v !== undefined && String(v).trim() !== '';

/**
 * The API's bounds on a deposit: more than 0, at most 100 and two decimal
 * places at most. '' when it would take it.
 */
export function depositPercentError(percent: Figure) {
  if (!isSet(percent)) return '';
  const v = Number(percent);
  if (!Number.isFinite(v) || v <= 0) return 'A deposit must be more than 0%.';
  if (v > 100) return 'A deposit cannot be more than 100%.';
  return Math.abs(v * 100 - Math.round(v * 100)) > 1e-6
    ? 'A deposit can have at most two decimal places.'
    : '';
}

/** What the builder shows for a deposit that rounds to nothing: the API drafts none. */
export const DEPOSIT_ROUNDS_TO_ZERO = 'Rounds to 0.00, so no deposit invoice is drafted.';

/**
 * The deposit as its invoice will bill it (`deposit_part`, `estimate_deposit`):
 * the percent of the total before tax (subtotal less the document discount),
 * rounded half up to the cent, plus the estimate's tax rate on that, rounded
 * half up again. In cents, so no float drift moves it. `subtotal` and
 * `discountAmount` are `documentTotals`' figures. Null with no usable percent.
 */
export function depositAmount({
  subtotal,
  discountAmount,
  taxRate,
  percent
}: {
  subtotal: number;
  discountAmount: number;
  taxRate: Figure;
  percent: Figure;
}): { pretax: number; total: number } | null {
  if (!isSet(percent) || depositPercentError(percent)) return null;
  const base = Math.max(0, hundredths(subtotal) - hundredths(discountAmount));
  const pretax = divHalfUp(base * hundredths(percent), 10000);
  const total = pretax + divHalfUp(pretax * hundredths(taxRate), 10000);
  return { pretax: pretax / 100, total: total / 100 };
}

/**
 * The builder's proposal fields as the API takes them, the deposit as a
 * decimal string with two places. The project goes only from an org admin
 * while Projects is on: the API refuses `start_project` and its billing type
 * from anyone else, and `start_project` with Projects off.
 */
export function proposalFields({
  introduction,
  depositPercent,
  startProject,
  billingType,
  projectsOn,
  isAdmin
}: {
  introduction: string;
  depositPercent: Figure;
  startProject: boolean;
  billingType: string;
  projectsOn: boolean;
  isAdmin: boolean;
}) {
  const body: {
    introduction?: string;
    deposit_percent?: string;
    start_project?: boolean;
    project_billing_type?: string;
  } = {};
  const intro = introduction.trim();
  if (intro) body.introduction = intro;
  if (isSet(depositPercent)) body.deposit_percent = num(depositPercent).toFixed(2);
  if (startProject && projectsOn && isAdmin) {
    body.start_project = true;
    body.project_billing_type = PROJECT_BILLING_TYPES.includes(billingType)
      ? billingType
      : 'fixed_fee';
  }
  return body;
}

/** 30, 12.5: a percent as a person writes it. */
const percentText = (p: Figure) => `${Number(num(p).toFixed(2))}%`;

/** The portal's line before the accept form; null without a deposit. */
export function depositOffer(
  deposit: { percent: Figure; amount: Figure; currency: string } | null | undefined
) {
  if (!deposit) return null;
  return `When you accept, a deposit invoice for ${percentText(deposit.percent)} (${money(num(deposit.amount), deposit.currency)}) follows.`;
}

export const DEPOSIT_FOLLOWS = 'A deposit invoice will follow.';

/**
 * What "Raise invoice" says first when the estimate already has a deposit
 * invoice that is not cancelled; null when it has none. The new invoice bills
 * every line: invoices take no negative lines and have no credits yet.
 */
export function convertNote(
  deposit: { invoice_number: string; status: string; total_amount: number } | null | undefined,
  currency: string
) {
  if (!deposit || deposit.status === 'Cancelled') return null;
  return `Deposit invoice ${deposit.invoice_number} for ${money(deposit.total_amount, currency)} is not taken off automatically. Edit the new invoice before you send it.`;
}

/** The row's copy when an estimate notification's data cannot be read, as on the phone. */
const ESTIMATE_FALLBACK: Record<string, string> = {
  'estimate.accepted': 'A client accepted an estimate.',
  'estimate.declined': 'A client declined an estimate.'
};

/**
 * The sentence for an `estimate.accepted` or `estimate.declined`
 * notification: the verb's fallback when `data` has no estimate number, and
 * null for another verb. A client name that is not text reads as "The client".
 */
export function estimateNotificationText(verb: string | undefined, data: unknown): string | null {
  if (verb !== 'estimate.accepted' && verb !== 'estimate.declined') return null;
  const d = data && typeof data === 'object' ? (data as Record<string, unknown>) : {};
  if (typeof d.estimate_number !== 'string' || !d.estimate_number.trim()) {
    return ESTIMATE_FALLBACK[verb];
  }
  const client = (typeof d.client_name === 'string' && d.client_name.trim()) || 'The client';
  if (verb === 'estimate.declined') return `${client} declined estimate ${d.estimate_number}`;
  const done = [
    typeof d.project_id === 'string' && d.project_id ? 'project started' : '',
    typeof d.deposit_invoice_id === 'string' && d.deposit_invoice_id
      ? 'deposit invoice drafted'
      : ''
  ].filter(Boolean);
  return [`${client} accepted estimate ${d.estimate_number}`, ...done].join(', ');
}
