/**
 * Billing on screen, browser-safe. `data.billing` is the shell's probe of
 * `GET /api/billing/` (`#lib/server/v2/billing.js`), null wherever billing is
 * not offered, so every check here starts from it.
 */
import { isOrgAdmin } from '#lib/admin.js';
import type { Billing, PlanOffer } from '#lib/server/v2/billing.js';

export const BILLING_HREF = '/settings/billing';

type BillingFacts =
  | {
      is_organization_admin?: boolean;
      billing?: Billing | null;
    }
  | null
  | undefined;

/**
 * Where an admin goes to lift a plan limit, or null for a member and on an
 * install without billing, where a refusal shows the server's sentence only.
 *
 * @param data layout data carrying `is_organization_admin` and `billing`
 */
export function billingHref(data: BillingFacts): string | null {
  return isOrgAdmin(data) && data?.billing ? BILLING_HREF : null;
}

/**
 * The shell's notice for an admin while a payment is failing. Left off the
 * Billing page, which shows the same notice beside the button that fixes it.
 */
export function shellNotice(data: BillingFacts, pathname: string): string | null {
  if (!billingHref(data) || pathname === BILLING_HREF) return null;
  return data?.billing?.notice?.sentence ?? null;
}

/**
 * The button a plan card carries, from the action the server gives it. Keep
 * belongs on the current plan, while a change away from it waits; Choose and
 * Switch never do. A switch is confirmed first with the server's sentence.
 */
export function planButton(
  plan: PlanOffer
): { action: 'choose' | 'switch' | 'keep'; label: string; confirm: string } | null {
  if (plan.action === 'keep') {
    return plan.current ? { action: 'keep', label: `Keep ${plan.name}`, confirm: '' } : null;
  }
  if (plan.current || !plan.action) return null;
  return plan.action === 'choose'
    ? { action: 'choose', label: `Choose ${plan.name}`, confirm: '' }
    : { action: 'switch', label: `Switch to ${plan.name}`, confirm: plan.confirm };
}
