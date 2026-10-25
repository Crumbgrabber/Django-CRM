import { describe, it, expect } from 'vitest';
import { dropSummary, limitNotice, dropPolicy } from './inbound-drops.js';

describe('dropSummary', () => {
  it('is null when the address dropped nothing', () => {
    expect(dropSummary({ dropped_last_30d: 0, drops_last_30d: {} })).toBeNull();
    expect(dropSummary({})).toBeNull();
    expect(dropSummary(/** @type {any} */ (null))).toBeNull();
  });

  it('names each reason in a fixed order, whatever order the API sent', () => {
    const line = dropSummary({
      dropped_last_30d: 12,
      drops_last_30d: { automatic: 1, spoofed: 2, spam: 9 }
    });
    expect(line).toBe(
      '12 dropped in 30 days: 9 spam, 2 failed the sender check, 1 automatic reply'
    );
  });

  it('puts virus after spam and other last', () => {
    const line = dropSummary({
      dropped_last_30d: 4,
      drops_last_30d: { other: 1, virus: 2, spam: 1 }
    });
    expect(line).toBe('4 dropped in 30 days: 1 spam, 2 with a virus, 1 other');
  });

  it('says reply for one and replies for more', () => {
    expect(dropSummary({ dropped_last_30d: 1, drops_last_30d: { automatic: 1 } })).toBe(
      '1 dropped in 30 days: 1 automatic reply'
    );
    expect(dropSummary({ dropped_last_30d: 3, drops_last_30d: { automatic: 3 } })).toBe(
      '3 dropped in 30 days: 3 automatic replies'
    );
  });

  it('leaves out a reason it does not know, and zero counts', () => {
    const line = dropSummary({
      dropped_last_30d: 5,
      drops_last_30d: { spam: 2, quarantined: 3, virus: 0 }
    });
    expect(line).toBe('5 dropped in 30 days: 2 spam');
  });

  it('states the total alone when there is no breakdown', () => {
    expect(dropSummary({ dropped_last_30d: 7 })).toBe('7 dropped in 30 days');
    expect(dropSummary({ dropped_last_30d: 7, drops_last_30d: { junk: 7 } })).toBe(
      '7 dropped in 30 days'
    );
  });

  it('groups thousands', () => {
    expect(dropSummary({ dropped_last_30d: 1200, drops_last_30d: { spam: 1200 } })).toBe(
      '1,200 dropped in 30 days: 1,200 spam'
    );
  });
});

describe('limitNotice', () => {
  it('is null unless the limit was reached', () => {
    expect(limitNotice(false, 300)).toBeNull();
    expect(limitNotice(undefined, 300)).toBeNull();
  });

  it('names the limit when the API sends one', () => {
    expect(limitNotice(true, 300)).toBe(
      'Took its limit of 300 emails today. More mail is refused until the count falls.'
    );
    expect(limitNotice(true, 1)).toBe(
      'Took its limit of 1 email today. More mail is refused until the count falls.'
    );
  });

  it('says its daily limit when the API sends none', () => {
    expect(limitNotice(true, null)).toBe(
      'Took its daily limit today. More mail is refused until the count falls.'
    );
    expect(limitNotice(true, undefined)).toBe(
      'Took its daily limit today. More mail is refused until the count falls.'
    );
  });
});

describe('dropPolicy', () => {
  it('states what is dropped and the limits, with the daily limit sent', () => {
    expect(dropPolicy(300)).toBe(
      "Spam, viruses and mail that fails its sender's domain check are dropped. Each address takes up to 300 emails a day, and a ticket address up to 20 an hour from one sender."
    );
    expect(dropPolicy(1000)).toContain('up to 1,000 emails a day');
  });

  it('says nothing for an API that sends no daily limit', () => {
    expect(dropPolicy(null)).toBeNull();
    expect(dropPolicy(undefined)).toBeNull();
    expect(dropPolicy(0)).toBeNull();
  });
});
