import { describe, it, expect } from 'vitest';
import {
  billActionUrl,
  billGrouping,
  defaultBillable,
  budgetNotificationText,
  burnMeter,
  burnTone,
  draftValues,
  hoursText,
  invoiceAmountBody,
  isoDateOrNull,
  projectBody,
  projectOptions,
  projectValues,
  rowBurn,
  taskProject,
  unratedText
} from '#lib/v2/projects.js';

function fd(entries: [string, string][]) {
  const f = new FormData();
  for (const [k, v] of entries) f.append(k, v);
  return f;
}

describe('the burn', () => {
  it('tones a share of a budget at the two notification levels', () => {
    expect(burnTone(null)).toBeNull();
    expect(burnTone(undefined)).toBeNull();
    expect(burnTone(0)).toBe('slate');
    expect(burnTone(79)).toBe('slate');
    expect(burnTone(80)).toBe('clay');
    expect(burnTone(99)).toBe('clay');
    expect(burnTone(100)).toBe('rust');
    expect(burnTone(140)).toBe('rust');
  });

  it('stops the bar at full and keeps the overrun in the percent', () => {
    expect(burnMeter(null)).toBeNull();
    expect(burnMeter(45)).toEqual({ percent: 45, width: 45, tone: 'slate' });
    expect(burnMeter(130)).toEqual({ percent: 130, width: 100, tone: 'rust' });
  });

  it('shows a list row the budget nearer to running out, or nothing without one', () => {
    expect(rowBurn({ hours_percent: null, amount_percent: null })).toBeNull();
    expect(rowBurn(undefined)).toBeNull();
    expect(rowBurn({ hours_percent: 85, amount_percent: 40 })).toMatchObject({
      kind: 'hours',
      label: '85% of hours',
      tone: 'clay'
    });
    expect(rowBurn({ hours_percent: 20, amount_percent: 100 })).toMatchObject({
      kind: 'amount',
      label: '100% of budget',
      tone: 'rust'
    });
    expect(rowBurn({ hours_percent: null, amount_percent: 10 })?.kind).toBe('amount');
  });

  it('writes decimal hours as the rest of the app writes time', () => {
    expect(hoursText('40.00')).toBe('40h');
    expect(hoursText('12.50')).toBe('12h 30m');
    expect(hoursText(0.75)).toBe('45m');
    expect(hoursText(null)).toBe('0h');
    expect(hoursText('nope')).toBe('0h');
  });
});

describe('budgetNotificationText', () => {
  it('says each level and kind', () => {
    expect(budgetNotificationText({ kind: 'hours', percent: 80, project: 'Rebuild' })).toBe(
      'Rebuild has used 80% of its hours budget'
    );
    expect(budgetNotificationText({ kind: 'amount', percent: 80, project: 'Rebuild' })).toBe(
      'Rebuild has used 80% of its amount budget'
    );
    expect(budgetNotificationText({ kind: 'hours', percent: 100, project: 'Rebuild' })).toBe(
      'Rebuild has used all of its hours budget'
    );
    expect(budgetNotificationText({ kind: 'amount', percent: 100, project: 'Rebuild' })).toBe(
      'Rebuild has used all of its amount budget'
    );
  });

  it('answers null for data of the wrong shape', () => {
    expect(budgetNotificationText(null)).toBeNull();
    expect(budgetNotificationText({ kind: 'days', percent: 80, project: 'R' })).toBeNull();
    expect(budgetNotificationText({ kind: 'hours', percent: '80', project: 'R' })).toBeNull();
    expect(budgetNotificationText({ kind: 'hours', percent: 0, project: 'R' })).toBeNull();
    expect(budgetNotificationText({ kind: 'hours', percent: 80, project: '' })).toBeNull();
    expect(budgetNotificationText({ kind: 'hours', percent: 80 })).toBeNull();
  });
});

describe('the project form', () => {
  it('reads only what the form rendered', () => {
    const values = projectValues(
      fd([
        ['name', '  Rebuild '],
        ['account', 'a1'],
        ['budget_hours', '40']
      ])
    );
    expect(values).toEqual({ name: 'Rebuild', account: 'a1', budget_hours: '40' });
    expect('assigned_to' in values).toBe(false);
    expect('rates' in values).toBe(false);
  });

  it('reads the people and pairs each rate with its person when both lists rendered', () => {
    const values = projectValues(
      fd([
        ['assigned__rendered', '1'],
        ['rates__rendered', '1'],
        ['rate_profile', 'p1'],
        ['rate_amount', '90'],
        ['rate_profile', ''],
        ['rate_amount', '']
      ])
    );
    expect(values.assigned_to).toEqual([]);
    expect(values.rates).toEqual([
      { profile: 'p1', hourly_rate: '90' },
      { profile: '', hourly_rate: '' }
    ]);
  });

  it('builds a create body with blanks as null and decimals as two-place strings', () => {
    const { body, errors } = projectBody({
      name: 'Rebuild',
      account: 'a1',
      deal: '',
      status: 'active',
      billing_type: 'fixed_fee',
      currency: 'EUR',
      budget_hours: '',
      budget_amount: '12000',
      hourly_rate: '95.5',
      start_date: '2026-11-01',
      due_date: '',
      description: 'Phase one',
      assigned_to: ['p1', 'p1', 'p2'],
      rates: [
        { profile: 'p1', hourly_rate: '90' },
        { profile: '', hourly_rate: '' }
      ]
    });
    expect(errors).toEqual([]);
    expect(body).toEqual({
      name: 'Rebuild',
      account: 'a1',
      deal: null,
      status: 'active',
      billing_type: 'fixed_fee',
      currency: 'EUR',
      budget_hours: null,
      budget_amount: '12000.00',
      hourly_rate: '95.50',
      start_date: '2026-11-01',
      due_date: null,
      description: 'Phase one',
      assigned_to: ['p1', 'p2'],
      rates: [{ profile: 'p1', hourly_rate: '90.00' }]
    });
  });

  it('leaves out of a PATCH what the form did not send', () => {
    const { body } = projectBody({ status: 'on_hold' });
    expect(body).toEqual({ status: 'on_hold' });
  });

  it('names what is wrong instead of sending it', () => {
    const { errors } = projectBody({
      name: ' ',
      account: '',
      budget_hours: '-1',
      hourly_rate: 'ten',
      start_date: '2026-11-10',
      due_date: '2026-11-01',
      rates: [
        { profile: 'p1', hourly_rate: '' },
        { profile: 'p2', hourly_rate: '50' },
        { profile: 'p2', hourly_rate: '60' }
      ]
    });
    expect(errors).toEqual([
      'Give the project a name.',
      'Pick the account this project is for.',
      'Budget hours must be a number of 0 or more.',
      'Hourly rate must be a number of 0 or more.',
      'The due date cannot be before the start date.',
      'Each person on the rates list needs a rate of 0 or more.',
      'A person can have only one rate on a project.'
    ]);
  });

  it('turns a malformed date into null rather than sending it', () => {
    expect(isoDateOrNull('2026-11-01')).toBe('2026-11-01');
    expect(isoDateOrNull('01/11/2026')).toBeNull();
    expect(projectBody({ start_date: 'soon' }).body.start_date).toBeNull();
  });

  it('fills the form from a deal draft, ids or objects alike', () => {
    expect(
      draftValues({
        name: 'Acme rebuild',
        account: 'a1',
        deal: { id: 'd1', name: 'Acme rebuild' },
        currency: 'GBP',
        assigned_to: ['p1', { id: 'p2' }],
        billing_type: 'fixed_fee',
        budget_amount: '12000.00'
      })
    ).toEqual({
      name: 'Acme rebuild',
      account: 'a1',
      deal: 'd1',
      currency: 'GBP',
      assigned_to: ['p1', 'p2'],
      billing_type: 'fixed_fee',
      budget_amount: '12000.00'
    });
    expect(draftValues({ billing_type: 'retainer', budget_amount: null })).toMatchObject({
      billing_type: '',
      budget_amount: ''
    });
    expect(draftValues(null)).toEqual({});
  });
});

describe('invoiceAmountBody', () => {
  it('sends exactly one of an amount or a percentage, and the description when typed', () => {
    expect(invoiceAmountBody({ mode: 'amount', value: '2500' }, null)).toEqual({
      body: { amount: '2500.00' }
    });
    expect(
      invoiceAmountBody({ mode: 'percent', value: '25', description: ' Deposit ' }, 12000)
    ).toEqual({ body: { percent: '25', description: 'Deposit' } });
  });

  it('refuses what the API would', () => {
    expect(invoiceAmountBody({ mode: 'amount', value: '0' }, null).error).toBe(
      'The amount must be more than 0.'
    );
    expect(invoiceAmountBody({ mode: 'percent', value: '120' }, 12000).error).toBe(
      'The percentage must be more than 0 and at most 100.'
    );
    expect(invoiceAmountBody({ mode: 'percent', value: '50' }, null).error).toBe(
      'Set a budget amount on the project before invoicing a percentage of it.'
    );
    expect(invoiceAmountBody({ mode: 'both', value: '1' }, 100).error).toBe(
      'Choose an amount or a percentage of the fee.'
    );
  });
});

describe('small readers', () => {
  it('keeps a grouping the API takes and falls back to its default', () => {
    expect(billGrouping('person')).toBe('person');
    expect(billGrouping('single')).toBe('single');
    expect(billGrouping('task')).toBe('task');
    expect(billGrouping('everything')).toBe('entry');
    expect(billGrouping(undefined)).toBe('entry');
  });

  it('reads a task project as an id or an expanded record', () => {
    expect(taskProject('p1')).toEqual({ id: 'p1', name: '' });
    expect(taskProject({ id: 'p1', name: 'Rebuild' })).toEqual({ id: 'p1', name: 'Rebuild' });
    expect(taskProject(null)).toBeNull();
    expect(taskProject({ name: 'no id' })).toBeNull();
  });
});

describe('the review fixes', () => {
  it('sends nothing of the money or the account from a member edit form', () => {
    // What ProjectForm posts for a member on edit: no money inputs, the
    // account shown as text, no rates list, the people list as usual.
    const values = projectValues(
      fd([
        ['name', 'Rebuild'],
        ['status', 'on_hold'],
        ['start_date', ''],
        ['due_date', ''],
        ['description', ''],
        ['assigned__rendered', '1'],
        ['assigned_to', 'p1']
      ])
    );
    const { body, errors } = projectBody(values);
    expect(errors).toEqual([]);
    for (const key of [
      'account',
      'billing_type',
      'currency',
      'budget_hours',
      'budget_amount',
      'hourly_rate',
      'rates'
    ]) {
      expect(body, key).not.toHaveProperty(key);
    }
    expect(body.assigned_to).toEqual(['p1']);
  });

  it('says how many entries will bill at 0, and nothing when all have a rate', () => {
    expect(unratedText(0)).toBe('');
    expect(unratedText(undefined)).toBe('');
    expect(unratedText(1)).toBe('1 entry has no rate and will be billed at 0.');
    expect(unratedText(3)).toBe('3 of these entries have no rate and will be billed at 0.');
  });

  it('posts the bill with the panel query kept, so a refusal shows without JavaScript', () => {
    expect(billActionUrl('2026-10-31')).toBe('?bill=1&up_to=2026-10-31&/billTime');
    expect(billActionUrl('soon')).toBe('?bill=1&/billTime');
  });

  it('keeps a chosen project the picker did not list, first, and only once', () => {
    const listed = [{ id: 'p1', name: 'One' }];
    expect(projectOptions(listed, { id: 'p9', name: 'Nine' })).toEqual([
      { id: 'p9', name: 'Nine' },
      { id: 'p1', name: 'One' }
    ]);
    expect(projectOptions(listed, { id: 'p1', name: 'One' })).toEqual(listed);
    expect(projectOptions(listed, null)).toEqual(listed);
  });

  it('starts time billable unless the project is non-billable', () => {
    expect(defaultBillable('time_and_materials')).toBe(true);
    expect(defaultBillable('fixed_fee')).toBe(true);
    expect(defaultBillable('non_billable')).toBe(false);
  });
});
