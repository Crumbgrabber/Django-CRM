import { describe, it, expect } from 'vitest';
import { usageColumns } from './tag-usage.js';

describe('usageColumns', () => {
  it('takes labels and order from the server', () => {
    expect(
      usageColumns({ accounts: 'Accounts', 'obj:property': 'Properties' }, [
        { usage: { 'obj:property': 2, accounts: 1 } }
      ])
    ).toEqual([
      { key: 'accounts', label: 'Accounts' },
      { key: 'obj:property', label: 'Properties' }
    ]);
  });

  it('shows a key the server did not label under its raw key', () => {
    expect(usageColumns({ leads: 'Leads' }, [{ usage: { leads: 1, macros: 3 } }])).toEqual([
      { key: 'leads', label: 'Leads' },
      { key: 'macros', label: 'Macros' }
    ]);
  });

  it('falls back to the phone words when usage_labels is missing', () => {
    expect(usageColumns(undefined, [{ usage: { accounts: 1 } }, { usage: { cases: 0 } }])).toEqual([
      { key: 'accounts', label: 'Accounts' },
      { key: 'cases', label: 'Tickets' }
    ]);
  });

  it('gives no columns for no labels and no tags', () => {
    expect(usageColumns(null, [])).toEqual([]);
  });
});
