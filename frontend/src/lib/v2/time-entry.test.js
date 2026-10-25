import { describe, it, expect } from 'vitest';
import {
  billableSharePercent,
  entryParent,
  isBilled,
  unbilledEntries
} from '#lib/v2/time-entry.js';

describe('isBilled', () => {
  it('reads an entry billed while Invoices is off as billed', () => {
    expect(isBilled({ invoiced: true, invoice: null })).toBe(true);
    expect(isBilled({ invoiced: false, invoice: null })).toBe(false);
    expect(isBilled({ invoice: 'id' })).toBe(true);
    expect(isBilled({ invoiced: false, invoice: { id: 'x' } })).toBe(true);
    expect(isBilled({})).toBe(false);
  });
});

describe('entryParent', () => {
  it('links a ticket entry, expanded or by id', () => {
    expect(entryParent({ case: { id: 't1', name: 'Login fails' }, project: null })).toEqual({
      kind: 'ticket',
      id: 't1',
      name: 'Login fails',
      href: '/tickets/t1'
    });
    expect(entryParent({ case: 't1' })).toMatchObject({ kind: 'ticket', name: 'A ticket' });
  });

  it('links a project entry by its id and name', () => {
    expect(entryParent({ case: null, project: 'p1', project_name: 'Rebuild' })).toEqual({
      kind: 'project',
      id: 'p1',
      name: 'Rebuild',
      href: '/projects/p1'
    });
    expect(entryParent({ case: null, project: 'p1', project_name: null })?.name).toBe('A project');
  });

  it('answers null for an entry whose project was deleted (both links null)', () => {
    expect(entryParent({ case: null, project: null, project_name: null })).toBeNull();
    expect(entryParent({})).toBeNull();
    expect(entryParent(null)).toBeNull();
  });
});

describe('unbilledEntries', () => {
  it('takes only stopped, billable, unbilled entries and names their currencies', () => {
    const entries = [
      { id: 'a', ended_at: 'x', billable: true, duration_minutes: 30, currency: 'USD' },
      { id: 'b', ended_at: 'x', billable: true, duration_minutes: 45, currency: 'EUR' },
      { id: 'c', ended_at: null, billable: true, duration_minutes: 0, currency: 'USD' },
      { id: 'd', ended_at: 'x', billable: false, duration_minutes: 60, currency: 'USD' },
      { id: 'e', ended_at: 'x', billable: true, invoiced: true, duration_minutes: 60 },
      { id: 'f', ended_at: 'x', billable: true, invoice: 'i1', duration_minutes: 60 }
    ];
    expect(unbilledEntries(entries)).toEqual({
      ids: ['a', 'b'],
      minutes: 75,
      currencies: ['EUR', 'USD']
    });
    expect(unbilledEntries(null)).toEqual({ ids: [], minutes: 0, currencies: [] });
  });
});

describe('billableSharePercent', () => {
  it('reads the API share, and null when there is no time', () => {
    expect(billableSharePercent({ billable_share: 0.75 })).toBe(75);
    expect(billableSharePercent({ billable_share: '0.33' })).toBe(33);
    expect(billableSharePercent({ billable_share: null, total_minutes: 0 })).toBeNull();
  });

  it('works the share out on an older API that sends only the minutes', () => {
    expect(billableSharePercent({ billable_minutes: 30, total_minutes: 120 })).toBe(25);
    expect(billableSharePercent({ billable_minutes: 0, total_minutes: 0 })).toBeNull();
  });
});
