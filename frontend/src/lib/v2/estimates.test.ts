import { describe, it, expect } from 'vitest';
import {
  convertNote,
  DEPOSIT_FOLLOWS,
  DEPOSIT_ROUNDS_TO_ZERO,
  depositAmount,
  depositOffer,
  depositPercentError,
  estimateNotificationText,
  proposalFields
} from '#lib/v2/estimates.js';
import { blankLine, documentTotals, lineTotals, type Line } from '#lib/v2/line-items.js';

describe('depositPercentError', () => {
  it('takes blank, a share above 0 and 100 itself', () => {
    for (const v of [null, undefined, '', '  ', 0.01, 30, '12.5', 33.33, '99.99', 100]) {
      expect(depositPercentError(v)).toBe('');
    }
  });

  it('refuses 0, a negative, over 100 and text', () => {
    expect(depositPercentError(0)).toBe('A deposit must be more than 0%.');
    expect(depositPercentError(-5)).toBe('A deposit must be more than 0%.');
    expect(depositPercentError('abc')).toBe('A deposit must be more than 0%.');
    expect(depositPercentError(100.01)).toBe('A deposit cannot be more than 100%.');
  });

  it('refuses more than two decimal places, as the API does', () => {
    for (const v of [12.345, '0.001', 33.333, '50.005']) {
      expect(depositPercentError(v)).toBe('A deposit can have at most two decimal places.');
    }
  });
});

describe('depositAmount', () => {
  it('takes the share of the total before tax, then charges the tax on it', () => {
    expect(depositAmount({ subtotal: 1000, discountAmount: 0, taxRate: 10, percent: 30 })).toEqual({
      pretax: 300,
      total: 330
    });
  });

  it('takes the document discount off first', () => {
    expect(depositAmount({ subtotal: 1000, discountAmount: 100, taxRate: 0, percent: 50 })).toEqual(
      { pretax: 450, total: 450 }
    );
  });

  it('rounds the part before tax half up to the cent', () => {
    // 20.1 x 5% = 1.005, which a float reads as 1.00499...
    expect(depositAmount({ subtotal: 20.1, discountAmount: 0, taxRate: 0, percent: 5 })).toEqual({
      pretax: 1.01,
      total: 1.01
    });
    expect(
      depositAmount({ subtotal: 100, discountAmount: 0, taxRate: 7.5, percent: 33.33 })
    ).toEqual({ pretax: 33.33, total: 35.83 });
  });

  it('has no amount without a usable percent', () => {
    for (const percent of [null, '', 0, 120, 12.345]) {
      expect(depositAmount({ subtotal: 100, discountAmount: 0, taxRate: 0, percent })).toBeNull();
    }
  });

  it('rounds the tax on the part half up to the cent', () => {
    // 4.25 + 0.425 and 1.15 + 0.115: a float reads both halves as a hair under.
    expect(depositAmount({ subtotal: 4.25, discountAmount: 0, taxRate: 10, percent: 100 })).toEqual(
      { pretax: 4.25, total: 4.68 }
    );
    expect(depositAmount({ subtotal: 1.15, discountAmount: 0, taxRate: 10, percent: 100 })).toEqual(
      { pretax: 1.15, total: 1.27 }
    );
  });

  it('comes to 0.00 when the share rounds to nothing, which drafts no invoice', () => {
    expect(depositAmount({ subtotal: 0.01, discountAmount: 0, taxRate: 10, percent: 10 })).toEqual({
      pretax: 0,
      total: 0
    });
    expect(DEPOSIT_ROUNDS_TO_ZERO).toBe('Rounds to 0.00, so no deposit invoice is drafted.');
  });
});

describe('the deposit the server bills, from the builder lines', () => {
  /** Lines and adjustments through the builder's own ladder, then the deposit. */
  function deposit(
    lines: Partial<Line>[],
    { discountType = '', discountValue = 0, taxRate = 0, percent = 0 } = {}
  ) {
    const usable = lineTotals(lines.map((l) => ({ ...blankLine(), name: 'Work', ...l }))).usable;
    const totals = documentTotals({ lines: usable, discountType, discountValue, taxRate });
    return depositAmount({
      subtotal: totals.subtotal,
      discountAmount: totals.discountAmount,
      taxRate,
      percent
    });
  }

  it('rounds the document discount to the cent before taking the share', () => {
    // 15% of 10.01 is 1.5015, billed as 1.50; half of 8.51 is 4.255, so 4.26.
    expect(
      deposit([{ quantity: 1, unit_price: 10.01 }], {
        discountType: 'PERCENTAGE',
        discountValue: 15,
        percent: 50
      })?.total
    ).toBe(4.26);
  });

  it("rounds each line's quantity x price to the cent first", () => {
    // 1.5 x 1.03 is 1.545, billed as 1.55; 30% of that is 0.465, so 0.47.
    expect(deposit([{ quantity: 1.5, unit_price: 1.03 }], { percent: 30 })?.total).toBe(0.47);
  });
});

describe('proposalFields', () => {
  const base = {
    introduction: '',
    depositPercent: null,
    startProject: false,
    billingType: 'fixed_fee',
    projectsOn: true,
    isAdmin: true
  };

  it('sends nothing for an estimate that is not a proposal', () => {
    expect(proposalFields(base)).toEqual({});
  });

  it('sends the introduction as typed, line breaks kept and ends trimmed', () => {
    expect(proposalFields({ ...base, introduction: '  Hello,\n\nThe plan.\n ' })).toEqual({
      introduction: 'Hello,\n\nThe plan.'
    });
  });

  it('sends the deposit as a decimal string with two places', () => {
    expect(proposalFields({ ...base, depositPercent: '25' })).toEqual({ deposit_percent: '25.00' });
    expect(proposalFields({ ...base, depositPercent: 12.5 })).toEqual({ deposit_percent: '12.50' });
    expect(proposalFields({ ...base, depositPercent: 33.33 })).toEqual({
      deposit_percent: '33.33'
    });
  });

  it('sends the project and its billing type only while Projects is on', () => {
    expect(
      proposalFields({ ...base, startProject: true, billingType: 'time_and_materials' })
    ).toEqual({ start_project: true, project_billing_type: 'time_and_materials' });
    expect(proposalFields({ ...base, startProject: true, projectsOn: false })).toEqual({});
  });

  it('never sends the project or its billing type for a member who is not an admin', () => {
    expect(
      proposalFields({
        ...base,
        isAdmin: false,
        startProject: true,
        billingType: 'time_and_materials',
        depositPercent: 30
      })
    ).toEqual({ deposit_percent: '30.00' });
  });

  it('falls back to a fixed fee for a billing type the API does not know', () => {
    expect(proposalFields({ ...base, startProject: true, billingType: 'retainer' })).toEqual({
      start_project: true,
      project_billing_type: 'fixed_fee'
    });
  });
});

describe('the portal deposit lines', () => {
  it('names the percent and the amount', () => {
    expect(depositOffer({ percent: '30.00', amount: '330.00', currency: 'USD' })).toBe(
      'When you accept, a deposit invoice for 30% ($330) follows.'
    );
    expect(depositOffer({ percent: '12.50', amount: '112.75', currency: 'EUR' })).toBe(
      'When you accept, a deposit invoice for 12.5% (€112.75) follows.'
    );
  });

  it('says nothing without a deposit', () => {
    expect(depositOffer(null)).toBeNull();
    expect(depositOffer(undefined)).toBeNull();
  });

  it('has a line for after accepting', () => {
    expect(DEPOSIT_FOLLOWS).toBe('A deposit invoice will follow.');
  });
});

describe('convertNote', () => {
  const deposit = { invoice_number: 'INV-0042', status: 'Draft', total_amount: 330 };

  it('names a live deposit invoice and its amount, and says it is not taken off', () => {
    expect(convertNote(deposit, 'USD')).toBe(
      'Deposit invoice INV-0042 for $330 is not taken off automatically. Edit the new invoice before you send it.'
    );
    expect(convertNote({ ...deposit, status: 'Paid' }, 'USD')).toContain('INV-0042');
  });

  it('asks nothing when there is no deposit invoice or it was cancelled', () => {
    expect(convertNote(null, 'USD')).toBeNull();
    expect(convertNote({ ...deposit, status: 'Cancelled' }, 'USD')).toBeNull();
  });
});

describe('estimateNotificationText', () => {
  const data = {
    estimate_number: 'EST-0007',
    client_name: 'Ada Lovelace',
    project_id: null,
    deposit_invoice_id: null
  };

  it('says who accepted which estimate, and what followed', () => {
    expect(estimateNotificationText('estimate.accepted', data)).toBe(
      'Ada Lovelace accepted estimate EST-0007'
    );
    expect(estimateNotificationText('estimate.accepted', { ...data, project_id: 'p1' })).toBe(
      'Ada Lovelace accepted estimate EST-0007, project started'
    );
    expect(
      estimateNotificationText('estimate.accepted', { ...data, deposit_invoice_id: 'i1' })
    ).toBe('Ada Lovelace accepted estimate EST-0007, deposit invoice drafted');
    expect(
      estimateNotificationText('estimate.accepted', {
        ...data,
        project_id: 'p1',
        deposit_invoice_id: 'i1'
      })
    ).toBe('Ada Lovelace accepted estimate EST-0007, project started, deposit invoice drafted');
  });

  it('says who declined', () => {
    expect(estimateNotificationText('estimate.declined', data)).toBe(
      'Ada Lovelace declined estimate EST-0007'
    );
    expect(estimateNotificationText('estimate.declined', { ...data, client_name: '' })).toBe(
      'The client declined estimate EST-0007'
    );
  });

  it('reads a client name that is not text as "The client"', () => {
    expect(estimateNotificationText('estimate.accepted', { ...data, client_name: 5 })).toBe(
      'The client accepted estimate EST-0007'
    );
    expect(estimateNotificationText('estimate.declined', { ...data, client_name: null })).toBe(
      'The client declined estimate EST-0007'
    );
  });

  it("falls back to the verb's own sentence when the data cannot be read", () => {
    for (const bad of [null, 'x', {}, { client_name: 'A' }, { ...data, estimate_number: 7 }]) {
      expect(estimateNotificationText('estimate.accepted', bad)).toBe(
        'A client accepted an estimate.'
      );
      expect(estimateNotificationText('estimate.declined', bad)).toBe(
        'A client declined an estimate.'
      );
    }
  });

  it('has nothing to say for another verb', () => {
    expect(estimateNotificationText('estimate.sent', data)).toBeNull();
    expect(estimateNotificationText(undefined, data)).toBeNull();
  });
});
