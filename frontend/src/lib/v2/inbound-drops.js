/**
 * What an inbound address refused, in the words the inbound email settings
 * page uses. `mobile/lib/data/models/mailbox.dart` says the same.
 */
import { count } from '#lib/v2/format.js';

/** The reasons the backend sends, in the order a row names them. */
const REASONS = [
  ['spam', 'spam', 'spam'],
  ['virus', 'with a virus', 'with a virus'],
  ['spoofed', 'failed the sender check', 'failed the sender check'],
  ['automatic', 'automatic reply', 'automatic replies'],
  ['other', 'other', 'other']
];

/** @param {unknown} n */
function positive(n) {
  const v = Number(n);
  return Number.isFinite(v) && v > 0 ? v : 0;
}

/**
 * "12 dropped in 30 days: 9 spam, 2 failed the sender check, 1 automatic
 * reply", or null when the address dropped nothing. A reason not in the list
 * above is left out of the breakdown but still counted in the total.
 *
 * @param {{ dropped_last_30d?: number, drops_last_30d?: Record<string, number> }} mailbox
 * @returns {string | null}
 */
export function dropSummary(mailbox) {
  const total = positive(mailbox?.dropped_last_30d);
  if (!total) return null;
  const parts = [];
  for (const [key, one, many] of REASONS) {
    const n = positive(mailbox?.drops_last_30d?.[key]);
    if (n) parts.push(`${count(n)} ${n === 1 ? one : many}`);
  }
  const head = `${count(total)} dropped in 30 days`;
  return parts.length ? `${head}: ${parts.join(', ')}` : head;
}

/** @param {number | null | undefined} dailyLimit */
function limitPhrase(dailyLimit) {
  const n = positive(dailyLimit);
  return n ? `its limit of ${count(n)} ${n === 1 ? 'email' : 'emails'}` : 'its daily limit';
}

/**
 * The warning for an address that has taken its daily limit, or null.
 *
 * @param {boolean | undefined} limitReached
 * @param {number | null | undefined} dailyLimit
 * @returns {string | null}
 */
export function limitNotice(limitReached, dailyLimit) {
  if (limitReached !== true) return null;
  return `Took ${limitPhrase(dailyLimit)} today. More mail is refused until the count falls.`;
}

/**
 * What every address refuses, for the page's explanation. Null when the API
 * sends no `daily_limit`: an API that old filters none of this, so the
 * sentence would be false.
 *
 * @param {number | null | undefined} dailyLimit
 * @returns {string | null}
 */
export function dropPolicy(dailyLimit) {
  const n = positive(dailyLimit);
  if (!n) return null;
  // The 20 is `cases.inbound.limits.SENDER_HOURLY_LIMIT`, which the API does not send.
  return (
    "Spam, viruses and mail that fails its sender's domain check are dropped. " +
    `Each address takes up to ${count(n)} ${n === 1 ? 'email' : 'emails'} a day, ` +
    'and a ticket address up to 20 an hour from one sender.'
  );
}
