/**
 * Server-side calls to /api/portal/, the customer self-service portal.
 *
 * The session cookie is `portal_access`, deliberately NOT `jwt_access`.
 * `hooks.server.js` reads `jwt_access`, `jwt_refresh` and `org` to decide
 * whether somebody is a signed-in staff user, so reusing those names would hand
 * a customer the application shell. `portal_org` rides alongside it purely so an
 * expired session knows which org's sign-in page to return to; it is an id that
 * already appears in the URL, not a credential.
 *
 * There is no refresh cookie. Portal tokens last 24 hours and the customer asks
 * for a new sign-in code after that, which keeps token rotation out of the
 * surface entirely. See the design note in `common/portal_auth.py`.
 */

import * as env from '$app/env/public';
import { relayHeaders } from '#lib/server/relay.js';

const API_BASE_URL = `${env.PUBLIC_DJANGO_API_URL}/api/portal`;

export const ACCESS_COOKIE = 'portal_access';
export const ORG_COOKIE = 'portal_org';

// Matches the 24 hour token lifetime in common/portal_auth.py. A cookie that
// outlived the token would leave the customer on a page that 401s instead of
// sending them to sign in again.
export const SESSION_MAX_AGE = 60 * 60 * 24;

// The org id deliberately outlives the session. It is not a credential (it is
// already in the URL of every email this org sends), and it is the only way an
// expired visitor can be returned to *their* sign-in page rather than to the
// staff login, which is a confusing dead end for a customer.
export const ORG_MAX_AGE = 60 * 60 * 24 * 365;

/** Thrown when the portal API answers with a non-2xx status. */
export class PortalError extends Error {
  /**
   * @param {number} status
   * @param {any} data
   */
  constructor(status, data) {
    super(`portal request failed with ${status}`);
    this.status = status;
    this.data = data;
  }
}

/**
 * @param {string} path
 * @param {{ method?: string, token?: string, body?: unknown, headers?: Record<string, string> }} [options]
 */
async function call(path, { method = 'GET', token, body, headers = {} } = {}) {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers
    },
    body: body === undefined ? undefined : JSON.stringify(body)
  });

  const text = await response.text();
  const data = text ? JSON.parse(text) : {};
  if (!response.ok) throw new PortalError(response.status, data);
  return data;
}

/**
 * The sign-in token records who asked for it, so the visitor's signed address
 * goes along (`#lib/server/relay.js`).
 *
 * @param {string} org
 * @param {string} email
 * @param {{ getClientAddress: () => string, request: Request }} event
 */
export const requestLogin = (org, email, event) =>
  call(`/login/${org}/request/`, {
    method: 'POST',
    body: { email },
    headers: relayHeaders(event)
  });

/**
 * @param {string} org
 * @param {string} email
 * @param {string} code
 */
export const verifyLogin = (org, email, code) =>
  call(`/login/${org}/verify/`, { method: 'POST', body: { email, code } });

/**
 * @param {string} token
 * @param {string} [status]
 */
export const listCases = (token, status) =>
  call(`/cases/${status ? `?status=${encodeURIComponent(status)}` : ''}`, { token });

/**
 * @param {string} token
 * @param {string} id
 */
export const getCase = (token, id) => call(`/cases/${id}/`, { token });

/**
 * @param {string} token
 * @param {{ name: string, description: string, priority: string }} body
 */
export const createCase = (token, body) => call('/cases/', { method: 'POST', token, body });

/**
 * @param {string} token
 * @param {string} id
 * @param {string} comment
 */
export const postReply = (token, id, comment) =>
  call(`/cases/${id}/comment/`, { method: 'POST', token, body: { comment } });

/**
 * @param {string} token
 * @param {string} [search]
 */
export const listArticles = (token, search) =>
  call(`/articles/${search ? `?search=${encodeURIComponent(search)}` : ''}`, { token });

/**
 * @param {string} token
 * @param {string} id
 */
export const getArticle = (token, id) => call(`/articles/${id}/`, { token });

/**
 * @param {string} token
 * @param {string} q
 */
export const suggestArticles = (token, q) =>
  call(`/articles/suggest/?q=${encodeURIComponent(q)}`, { token });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Where to send a visitor with no usable session.
 *
 * `/login` is the staff sign-in, which a customer cannot use, so it is the last
 * resort and not the default. The org is checked only for being a UUID, which
 * is all that is needed to build a path we control; it grants nothing, so a
 * wrong one costs a visitor a sign-in page that will never email them.
 *
 * @param {string | null | undefined} org
 */
export const loginPath = (org) => (org && UUID.test(org) ? `/portal/login/${org}` : '/login');

/**
 * Write the session, httpOnly so no script on the page can read the token.
 *
 * @param {import('@sveltejs/kit').Cookies} cookies
 * @param {string} accessToken
 * @param {string} orgId
 */
export function setSession(cookies, accessToken, orgId) {
  /** @type {Parameters<import('@sveltejs/kit').Cookies['set']>[2]} */
  const options = {
    path: '/',
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
    maxAge: SESSION_MAX_AGE
  };
  cookies.set(ACCESS_COOKIE, accessToken, options);
  cookies.set(ORG_COOKIE, orgId, { ...options, httpOnly: false, maxAge: ORG_MAX_AGE });
}

/**
 * Drop the credential, keep the signpost.
 *
 * `portal_org` survives on purpose so the next visit lands on the right org's
 * sign-in page. Clearing it too would send a returning customer to the staff
 * login, which they cannot use.
 *
 * @param {import('@sveltejs/kit').Cookies} cookies
 */
export function clearSession(cookies) {
  cookies.delete(ACCESS_COOKIE, { path: '/' });
}
