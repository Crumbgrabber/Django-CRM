import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import {
  billingRefusal,
  changePlan,
  isPlanKey,
  openCheckout,
  openPortal,
  readBilling,
  syncCheckout
} from '#lib/server/v2/billing.js';
import { BILLING_HREF } from '#lib/v2/billing.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';

const NO_PAYMENT_PAGE = 'The payment page could not be opened. Try again.';
const NO_PORTAL = 'The billing portal could not be opened. Try again.';
const NO_CHANGE = 'The plan could not be changed. Try again.';

/**
 * Settings › Billing, rendered from the server's answer. The way back from the
 * payment page carries `session_id`: it is synced once and dropped from the
 * address, so a reload never syncs again.
 */
export const load: PageServerLoad = async (event) => {
  const session = event.url.searchParams.get('session_id');
  if (session !== null) {
    await syncCheckout(event, session);
    redirect(303, BILLING_HREF);
  }
  return { answer: await readBilling(event) };
};

const statusOf = (err: unknown) => {
  const status = apiStatus(err);
  return status !== undefined && Number.isInteger(status) && status >= 400 && status < 600
    ? status
    : 400;
};

/**
 * Both actions leave for an address the server returns, or come back with a
 * sentence and the plan whose button was pressed, so it shows beside that one.
 */
async function leaveFor(
  event: RequestEvent,
  open: (plan: unknown) => Promise<string | null>,
  fallback: string
) {
  const form = await event.request.formData();
  const plan = form.get('plan');
  const shown = isPlanKey(plan) ? plan : null;
  let url: string | null;
  try {
    url = await open(plan);
  } catch (err) {
    return fail(statusOf(err), { error: billingRefusal(err, fallback), plan: shown });
  }
  if (!url) return fail(502, { error: fallback, plan: shown });
  // `url` passed `paymentPageUrl`: https, no credentials.
  redirect(303, url, { external: true });
}

/**
 * Switch and Keep stay on this page: the server's sentence for what it did,
 * or its refusal beside the plan whose button was pressed.
 */
async function change(event: RequestEvent) {
  const plan = (await event.request.formData()).get('plan');
  const shown = isPlanKey(plan) ? plan : null;
  try {
    return { message: (await changePlan(event, plan)) || null, plan: shown };
  } catch (err) {
    return fail(statusOf(err), { error: billingRefusal(err, NO_CHANGE), plan: shown });
  }
}

export const actions: Actions = {
  choose: (event) => leaveFor(event, (plan) => openCheckout(event, plan), NO_PAYMENT_PAGE),
  manage: (event) => leaveFor(event, () => openPortal(event), NO_PORTAL),
  switch: change,
  keep: change
};
