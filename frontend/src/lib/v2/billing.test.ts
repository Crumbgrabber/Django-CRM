import { describe, it, expect } from 'vitest';
import { BILLING_HREF, billingHref, planButton, shellNotice } from './billing.js';

const billing = (more = {}) => ({
  plan: { key: 'a', name: 'Plan A' },
  canManage: true,
  state: null,
  notice: null,
  plans: [],
  ...more
});

describe('billingHref', () => {
  it('points an admin at Billing where the server offers it', () => {
    expect(billingHref({ is_organization_admin: true, billing: billing() })).toBe(
      '/settings/billing'
    );
    expect(BILLING_HREF).toBe('/settings/billing');
  });

  it('is null for a member, and wherever billing is not offered', () => {
    expect(billingHref({ is_organization_admin: false, billing: billing() })).toBeNull();
    expect(billingHref({ is_organization_admin: true, billing: null })).toBeNull();
    expect(billingHref({ is_organization_admin: true })).toBeNull();
    expect(billingHref(null)).toBeNull();
  });
});

describe('shellNotice', () => {
  const failing = billing({ notice: { sentence: 'The last payment failed.' } });

  it('shows an admin the server notice on every page but Billing itself', () => {
    const data = { is_organization_admin: true, billing: failing };
    expect(shellNotice(data, '/leads')).toBe('The last payment failed.');
    expect(shellNotice(data, '/settings')).toBe('The last payment failed.');
    expect(shellNotice(data, '/settings/billing')).toBeNull();
  });

  it('shows nothing to a member, without a notice, or without billing', () => {
    expect(shellNotice({ is_organization_admin: false, billing: failing }, '/')).toBeNull();
    expect(shellNotice({ is_organization_admin: true, billing: billing() }, '/')).toBeNull();
    expect(shellNotice({ is_organization_admin: true, billing: null }, '/')).toBeNull();
  });
});

describe('planButton', () => {
  const plan = (more: Record<string, any>) => ({
    key: 'b',
    name: 'Plan B',
    priceText: '',
    features: [],
    current: false,
    action: null,
    confirm: '',
    ...more
  });

  it('chooses a plan the server offers to buy', () => {
    expect(planButton(plan({ action: 'choose' }))).toEqual({
      action: 'choose',
      label: 'Choose Plan B',
      confirm: ''
    });
  });

  it("switches to another paid plan, carrying the server's sentence to confirm", () => {
    expect(planButton(plan({ action: 'switch', confirm: 'Plan B starts now.' }))).toEqual({
      action: 'switch',
      label: 'Switch to Plan B',
      confirm: 'Plan B starts now.'
    });
  });

  it('keeps the current plan while a change away from it waits', () => {
    expect(planButton(plan({ action: 'keep', current: true }))).toEqual({
      action: 'keep',
      label: 'Keep Plan B',
      confirm: ''
    });
  });

  it('gives no button where the action does not fit the card', () => {
    expect(planButton(plan({ action: 'switch', current: true }))).toBeNull();
    expect(planButton(plan({ action: 'choose', current: true }))).toBeNull();
    expect(planButton(plan({ action: 'keep', current: false }))).toBeNull();
    expect(planButton(plan({ action: null }))).toBeNull();
    expect(planButton(plan({ action: null, current: true }))).toBeNull();
  });
});
