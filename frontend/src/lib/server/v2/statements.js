/**
 * Account statements (#810): what one account was billed and paid over a
 * period, from `GET /api/invoices/statements/<account>/` and its `pdf/` twin.
 *
 * Per currency the API sends an opening balance, the period's invoices,
 * payments and cancellations in date order with a running balance, and a
 * closing balance. It does all the arithmetic; nothing here adds money up.
 *
 * Admin-only on the backend, like the invoice reports: a statement sums every
 * invoice on the account, including ones a member may not open. A member's 403
 * comes back as `can_view: false` so the page can say so. The account page
 * only offers the link to admins, but that is courtesy, not the control.
 */
import { error } from '@sveltejs/kit';
import * as env from '$app/env/public';
import { apiRequest } from '#lib/api-helpers.js';
import { moduleOffDetail, rethrowModuleOff } from '#lib/server/v2/modules.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiErrorBody, apiStatus } from '#lib/api-errors.js';

/** @typedef {import('#lib/api-schema.js').components['schemas']} Schemas */

const num = (/** @type {unknown} */ value) => {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
};

/**
 * The API query for the period in the page's own URL: `start_date` and
 * `end_date`, blanks left out so the API's default (this month so far) applies.
 *
 * @param {URLSearchParams} searchParams
 */
export function statementQuery(searchParams) {
  const query = new URLSearchParams();
  for (const name of ['start_date', 'end_date']) {
    const value = searchParams.get(name)?.trim();
    if (value) query.set(name, value);
  }
  const qs = query.toString();
  return qs ? `?${qs}` : '';
}

/**
 * The whole calendar month before the one `iso` falls in, as the period the
 * page links to. Statements are read a month at a time, and stepping back by
 * a link beats two date pickers on a phone.
 *
 * @param {string} iso YYYY-MM-DD
 */
export function previousMonth(iso) {
  const [y, m] = iso.split('-').map(Number);
  const year = m === 1 ? y - 1 : y;
  const month = m === 1 ? 12 : m - 1;
  // Day 0 of the next month is this month's last day; `month` is 1-based,
  // which is the next month to `Date.UTC`'s 0-based count.
  const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const mm = String(month).padStart(2, '0');
  return { start_date: `${year}-${mm}-01`, end_date: `${year}-${mm}-${last}` };
}

/** @param {Schemas['StatementCurrency']} section */
function toSection(section) {
  return {
    currency: section.currency,
    opening_balance: num(section.opening_balance),
    invoiced: num(section.invoiced),
    paid: num(section.paid),
    cancelled: num(section.cancelled),
    closing_balance: num(section.closing_balance),
    entries: (section.entries ?? []).map((entry) => ({
      date: entry.date,
      kind: entry.kind,
      invoice_id: entry.invoice_id,
      invoice_number: entry.invoice_number ?? '',
      description: entry.description ?? '',
      amount: num(entry.amount),
      balance: num(entry.balance)
    }))
  };
}

/**
 * `{ can_view, statement, error }`. `statement` is null when the caller is not
 * an admin (`can_view: false`) or the period was refused (`error` says why).
 *
 * @param {{ cookies: import('@sveltejs/kit').Cookies }} event
 * @param {string} accountId
 * @param {URLSearchParams} searchParams the page's own query string
 */
export async function getStatement({ cookies }, accountId, searchParams) {
  /** @type {Schemas['AccountStatement']} */
  let body;
  try {
    body = await apiRequest(
      `/invoices/statements/${accountId}/${statementQuery(searchParams)}`,
      {},
      { cookies }
    );
  } catch (err) {
    if (apiStatus(err) === 403) return { can_view: false, statement: null, error: null };
    rethrowModuleOff(err);
    if (apiStatus(err) === 404) {
      error(404, 'That account does not exist, or you do not have access to it.');
    }
    if (apiStatus(err) === 400) {
      // `{"end_date": ["..."]}`: the sentence alone, the field is on the form.
      const said = Object.values(apiErrorBody(err) ?? {})
        .flat()
        .find((m) => typeof m === 'string');
      return {
        can_view: true,
        statement: null,
        error: said ?? readableError(err, 'Those dates do not make a period.')
      };
    }
    throw err;
  }

  return {
    can_view: true,
    error: null,
    statement: {
      account: { id: body.account?.id ?? accountId, name: body.account?.name ?? '' },
      start_date: body.start_date,
      end_date: body.end_date,
      currencies: (body.currencies ?? []).map(toSection)
    }
  };
}

/**
 * Stream the statement PDF for `/accounts/<id>/statement/pdf?<period>`.
 *
 * The access token is an httpOnly cookie that a plain link cannot attach, so
 * this carries it. It never gates: the API decides, and a refusal is passed on
 * as a refusal rather than as a file.
 *
 * @param {{ cookies: import('@sveltejs/kit').Cookies, params: { id: string }, url: URL, request: Request }} event
 */
export async function forwardStatementPdf({ cookies, params, url, request }) {
  const accessToken = cookies.get('jwt_access');
  if (!accessToken) return new Response('Unauthorized', { status: 401 });

  const upstream = await fetch(
    `${env.PUBLIC_DJANGO_API_URL}/api/invoices/statements/${params.id}/pdf/${statementQuery(url.searchParams)}`,
    { headers: { Authorization: `Bearer ${accessToken}` }, signal: request.signal }
  );

  if (!upstream.ok || !upstream.body) {
    return new Response((await moduleOffDetail(upstream)) ?? `Upstream error: ${upstream.status}`, {
      status: upstream.status || 502
    });
  }

  return new Response(upstream.body, {
    status: 200,
    headers: {
      'Content-Type': 'application/pdf',
      'Content-Disposition':
        upstream.headers.get('Content-Disposition') ?? 'attachment; filename="statement.pdf"'
    }
  });
}
