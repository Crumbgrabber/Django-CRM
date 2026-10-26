/**
 * Billing (`/api/billing/`): the org's plan for every member and, for admins,
 * its state, a notice while a payment is failing, and the plans on offer with
 * the button each one gets. Every name, price and sentence comes from the
 * server; this edition holds none. An install without billing answers 404,
 * so nothing anywhere mentions billing there.
 *
 * Choosing a plan and managing it both leave for a page the server names, so
 * its address is checked before anyone is sent to it. Switching between plans
 * the org already pays for stays on this page.
 */
import { error, type Cookies } from '@sveltejs/kit';
import { apiErrorBody, apiStatus } from '#lib/api-errors.js';
import { apiRequest } from '#lib/api-helpers.js';
import { readableError } from '#lib/server/v2/form-errors.js';

const ABSENT_FOR_MS = 5 * 60 * 1000;
const PLAN_KEY = /^[a-z][a-z0-9_]{0,31}$/;
const SESSION_ID = /^[A-Za-z0-9_]{1,255}$/;
const ACTIONS = ['choose', 'switch', 'keep'];
const PLAN_CODES = ['plan_limit', 'plan_required'];
const NOT_OFFERED = 'Billing is not available here.';

type Event = { cookies: Cookies };

/**
 * What the enterprise `billing_body` sends: `plan` and `can_manage` to every
 * member, the rest to admins only. `POST /billing/change/` adds `message`.
 */
type BillingPlanBody = {
  key: string;
  name: string;
  price_text: string;
  features: string[];
  current: boolean;
  action: 'choose' | 'switch' | 'keep' | null;
  confirm: string | null;
};

type BillingBody = {
  plan: { key: string; name: string };
  can_manage: boolean;
  state?: { code: string; sentence: string };
  notice?: { sentence: string } | null;
  plans?: BillingPlanBody[];
};

type BillingChangeBody = BillingBody & { message: string };

type BillingRedirectBody = { url: string };

export type PlanOffer = {
  key: string;
  name: string;
  priceText: string;
  features: string[];
  current: boolean;
  action: 'choose' | 'switch' | 'keep' | null;
  confirm: string;
};

export type Billing = {
  plan: { key: string; name: string };
  canManage: boolean;
  state: { code: string; sentence: string } | null;
  notice: { sentence: string } | null;
  plans: PlanOffer[] | null;
};

export function isPlanKey(key: unknown) {
  return typeof key === 'string' && PLAN_KEY.test(key);
}

export function isSessionId(id: unknown) {
  return typeof id === 'string' && SESSION_ID.test(id);
}

const text = (value: unknown) => (typeof value === 'string' ? value.trim() : '');

function toPlan(raw: BillingPlanBody): PlanOffer | null {
  if (!isPlanKey(raw?.key) || !text(raw?.name)) return null;
  return {
    key: raw.key,
    name: text(raw.name),
    priceText: text(raw.price_text),
    features: Array.isArray(raw.features) ? raw.features.map(text).filter(Boolean) : [],
    current: raw.current === true,
    action: raw.action && ACTIONS.includes(raw.action) ? raw.action : null,
    confirm: text(raw.confirm)
  };
}

function toBilling(raw: BillingBody): Billing | null {
  const name = text(raw?.plan?.name);
  if (!name || typeof raw.plan.key !== 'string') return null;
  const sentence = text(raw.state?.sentence);
  const notice = text(raw.notice?.sentence);
  return {
    plan: { key: raw.plan.key, name },
    canManage: raw.can_manage === true,
    state: sentence ? { code: text(raw.state?.code), sentence } : null,
    notice: notice ? { sentence: notice } : null,
    plans: Array.isArray(raw.plans) ? toPlans(raw.plans) : null
  };
}

/** Each plan once, by key, since the page keys its cards on it. */
function toPlans(rows: BillingPlanBody[]): PlanOffer[] {
  const byKey: Map<string, PlanOffer> = new Map();
  for (const plan of rows.map(toPlan)) {
    if (plan && !byKey.has(plan.key)) byKey.set(plan.key, plan);
  }
  return [...byKey.values()];
}

/**
 * Set when `GET /billing/` answers 404, so an install without billing is asked
 * once per 5 minutes per process, not on every page.
 */
let absentUntil = 0;

const absent = () => Date.now() < absentUntil;

/** Forget the absent memo; for tests. */
export function resetBillingAbsentMemo() {
  absentUntil = 0;
}

/**
 * The probe the shell runs: the answer, or null where billing is not offered
 * or the read failed for any reason.
 */
export async function getBilling({ cookies }: Event): Promise<Billing | null> {
  if (absent()) return null;
  try {
    const body: BillingBody = await apiRequest(
      '/billing/',
      { quietErrors: true, expectedStatuses: [404] },
      { cookies }
    );
    absentUntil = 0;
    return toBilling(body);
  } catch (err) {
    if (apiStatus(err) === 404) absentUntil = Date.now() + ABSENT_FOR_MS;
    return null;
  }
}

/**
 * The Billing page's read: a page 404 where billing is not offered, and any
 * other failure left to the error page rather than shown as "no billing".
 */
export async function readBilling({ cookies }: Event): Promise<Billing> {
  if (absent()) error(404, NOT_OFFERED);
  let body: BillingBody;
  try {
    body = await apiRequest('/billing/', { expectedStatuses: [404] }, { cookies });
  } catch (err) {
    if (apiStatus(err) === 404) {
      absentUntil = Date.now() + ABSENT_FOR_MS;
      error(404, NOT_OFFERED);
    }
    throw err;
  }
  absentUntil = 0;
  const answer = toBilling(body);
  if (!answer) error(502, 'Billing could not be read. Try again.');
  return answer;
}

/**
 * Syncs the org with a finished payment-page visit, so the new plan shows
 * without waiting for the server's own notification. Best effort: the server
 * refuses another org's session, and a failure leaves that notification to
 * bring the change.
 */
export async function syncCheckout({ cookies }: Event, sessionId: unknown): Promise<boolean> {
  if (!isSessionId(sessionId)) return false;
  try {
    await apiRequest(
      `/billing/?session=${encodeURIComponent(sessionId as string)}`,
      { quietErrors: true, expectedStatuses: [403, 404] },
      { cookies }
    );
    return true;
  } catch {
    return false;
  }
}

/**
 * An https address to send the browser to, or null. Anything else (another
 * scheme, a relative path, embedded credentials) is never followed.
 */
export function paymentPageUrl(raw: unknown): string | null {
  if (typeof raw !== 'string' || raw.length > 4096) return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || url.username || url.password) return null;
  return url.href;
}

/** A plan that is not a key is refused here, as the API would refuse it. */
function requirePlanKey(plan: unknown) {
  if (!isPlanKey(plan)) {
    throw Object.assign(new Error('That plan is not available.'), {
      status: 400,
      body: { detail: 'That plan is not available.' }
    });
  }
}

/**
 * The payment page for `plan`, or null when the server's address is unusable.
 * Throws the API's refusal (400, 403, 404, 409) as it came.
 */
export async function openCheckout({ cookies }: Event, plan: unknown): Promise<string | null> {
  requirePlanKey(plan);
  const body: BillingRedirectBody = await apiRequest(
    '/billing/checkout/',
    { method: 'POST', body: { plan }, expectedStatuses: [400, 403, 404, 409] },
    { cookies }
  );
  return paymentPageUrl(body?.url);
}

/**
 * The billing portal, or null when the server's address is unusable. Throws
 * the API's refusal as it came.
 */
export async function openPortal({ cookies }: Event): Promise<string | null> {
  const body: BillingRedirectBody = await apiRequest(
    '/billing/portal/',
    { method: 'POST', expectedStatuses: [403, 404, 409] },
    { cookies }
  );
  return paymentPageUrl(body?.url);
}

/**
 * Switches the org's paid plan, or keeps the current one while a change waits,
 * and answers the server's sentence for what it did. Throws the API's refusal
 * (400, 402, 403, 404, 409) as it came.
 */
export async function changePlan({ cookies }: Event, plan: unknown): Promise<string> {
  requirePlanKey(plan);
  const body: BillingChangeBody = await apiRequest(
    '/billing/change/',
    { method: 'POST', body: { plan }, expectedStatuses: [400, 402, 403, 404, 409] },
    { cookies }
  );
  return text(body?.message);
}

/**
 * A refused billing action as a sentence. A 400, 402 or 409 carries the
 * server's own reason; a server or network failure gets `fallback`, never a
 * status line.
 */
export function billingRefusal(err: unknown, fallback: string): string {
  const status = apiStatus(err);
  if (status === 403) return 'Only an organization admin can change the plan.';
  if (status === 404) return NOT_OFFERED;
  if (status === undefined || !Number.isInteger(status) || status < 400 || status >= 500)
    return fallback;
  const detail = text(apiErrorBody(err)?.detail);
  return detail || readableError(err, fallback);
}

/**
 * Whether an API refusal is a plan limit, which an admin may lift on the
 * Billing page.
 */
export function isPlanRefusal(err: unknown): boolean {
  const code = apiErrorBody(err)?.code;
  return apiStatus(err) === 403 && typeof code === 'string' && PLAN_CODES.includes(code);
}
