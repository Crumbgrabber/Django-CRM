/**
 * Where a new org came from: the first visit's campaign tags and the host that
 * referred it, kept in a cookie until the org is created, then sent with the
 * create. The API cleans the value again; nothing here is a check.
 */

import type { Cookies } from '@sveltejs/kit';

export const SIGNUP_SOURCE_COOKIE = 'signup_source';

const TAGS = ['utm_source', 'utm_medium', 'utm_campaign'];
const MAX_LENGTH = 100;
const THIRTY_DAYS = 60 * 60 * 24 * 30;

/**
 * The tags on this URL, and the referring host unless it is this app's own.
 * Only the host of a referrer is kept: its path or query can carry tokens.
 */
export function sourceOfVisit(url: URL, referer: string | null): Record<string, string> {
  const source: Record<string, string> = {};
  for (const tag of TAGS) {
    const value = url.searchParams.get(tag)?.trim();
    if (value) source[tag] = value.slice(0, MAX_LENGTH);
  }
  if (referer) {
    try {
      const host = new URL(referer).hostname.toLowerCase();
      if (host && host !== url.hostname.toLowerCase()) source.referrer = host;
    } catch {
      // A malformed header names no source.
    }
  }
  return source;
}

/**
 * Remember this visit's source unless an earlier visit already did: the first
 * visit is the one that brought the person here.
 */
export function rememberSignupSource(
  { url, request, cookies }: { url: URL; request: Request; cookies: Cookies },
  secure: boolean
) {
  if (cookies.get(SIGNUP_SOURCE_COOKIE) !== undefined) return;
  const source = sourceOfVisit(url, request.headers.get('referer'));
  cookies.set(SIGNUP_SOURCE_COOKIE, JSON.stringify(source), {
    path: '/',
    httpOnly: true,
    sameSite: 'lax',
    secure,
    maxAge: THIRTY_DAYS
  });
}

/** The remembered source, or undefined when there is none or it will not parse. */
export function readSignupSource(cookies: {
  get: (name: string) => string | undefined;
}): Record<string, unknown> | undefined {
  const raw = cookies.get(SIGNUP_SOURCE_COOKIE);
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw);
    return value && typeof value === 'object' && !Array.isArray(value) ? value : undefined;
  } catch {
    return undefined;
  }
}
