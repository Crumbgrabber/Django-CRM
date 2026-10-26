/**
 * Server-side calls to /api/portal/, the customer self-service portal.
 *
 * The session cookie is `portal_access`, deliberately NOT `jwt_access`.
 * `hooks.server.ts` reads `jwt_access`, `jwt_refresh` and `org` to decide
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
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

/**
 * A portal error reply: `{ error }` from the portal views, `{ detail }` from
 * DRF's auth and throttle answers, or a serializer's field errors.
 */
type PortalErrorBody = {
  error?: string;
  detail?: string;
  [field: string]: string | string[] | undefined;
};

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
  declare status: number;
  declare data: PortalErrorBody;

  constructor(status: number, data: PortalErrorBody) {
    super(`portal request failed with ${status}`);
    this.status = status;
    this.data = data;
  }
}

async function call<T = unknown>(
  path: string,
  {
    method = 'GET',
    token,
    body,
    headers = {}
  }: { method?: string; token?: string; body?: unknown; headers?: Record<string, string> } = {}
): Promise<T> {
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
  const data: unknown = text ? JSON.parse(text) : {};
  if (!response.ok) throw new PortalError(response.status, data as PortalErrorBody);
  return data as T;
}

/**
 * The sign-in token records who asked for it, so the visitor's signed address
 * goes along (`#lib/server/relay.js`).
 */
export const requestLogin = (
  org: string,
  email: string,
  event: { getClientAddress: () => string; request: Request }
): Promise<Schemas['PortalLoginCodeSentResponse']> =>
  call(`/login/${org}/request/`, {
    method: 'POST',
    body: { email },
    headers: relayHeaders(event)
  });

export const verifyLogin = (
  org: string,
  email: string,
  code: string
): Promise<Schemas['PortalLoginVerifyResponse']> =>
  call(`/login/${org}/verify/`, { method: 'POST', body: { email, code } });

export const listCases = (
  token: string,
  status?: string
): Promise<Schemas['PortalCaseListResponse']> =>
  call(`/cases/${status ? `?status=${encodeURIComponent(status)}` : ''}`, { token });

export const getCase = (token: string, id: string): Promise<Schemas['PortalCaseDetailResponse']> =>
  call(`/cases/${id}/`, { token });

export const createCase = (
  token: string,
  body: { name: string; description: string; priority: string }
): Promise<Schemas['PortalCaseCreateResponse']> => call('/cases/', { method: 'POST', token, body });

export const postReply = (
  token: string,
  id: string,
  comment: string
): Promise<Schemas['PortalCommentCreateResponse']> =>
  call(`/cases/${id}/comment/`, { method: 'POST', token, body: { comment } });

export const listArticles = (
  token: string,
  search?: string
): Promise<Schemas['PortalArticleListResponse']> =>
  call(`/articles/${search ? `?search=${encodeURIComponent(search)}` : ''}`, { token });

export const getArticle = (
  token: string,
  id: string
): Promise<Schemas['PortalArticleDetailResponse']> => call(`/articles/${id}/`, { token });

export const suggestArticles = (
  token: string,
  q: string
): Promise<Schemas['PortalArticleSuggestResponse']> =>
  call(`/articles/suggest/?q=${encodeURIComponent(q)}`, { token });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Where to send a visitor with no usable session.
 *
 * `/login` is the staff sign-in, which a customer cannot use, so it is the last
 * resort and not the default. The org is checked only for being a UUID, which
 * is all that is needed to build a path we control; it grants nothing, so a
 * wrong one costs a visitor a sign-in page that will never email them.
 */
export const loginPath = (org: string | null | undefined) =>
  org && UUID.test(org) ? `/portal/login/${org}` : '/login';

/** Write the session, httpOnly so no script on the page can read the token. */
export function setSession(cookies: Cookies, accessToken: string, orgId: string) {
  const options: Parameters<Cookies['set']>[2] = {
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
 */
export function clearSession(cookies: Cookies) {
  cookies.delete(ACCESS_COOKIE, { path: '/' });
}
