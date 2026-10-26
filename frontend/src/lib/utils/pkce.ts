/**
 * PKCE (Proof Key for Code Exchange) utilities for OAuth 2.0
 * @module lib/utils/pkce
 */

/**
 * Generate a random code verifier for PKCE
 * @returns Random code verifier string
 */
export function generateCodeVerifier(): string {
  const array = new Uint8Array(32);
  crypto.getRandomValues(array);
  return base64URLEncode(array);
}

/**
 * Generate a code challenge from a verifier using SHA-256
 * @param verifier The code verifier
 * @returns Code challenge
 */
export async function generateCodeChallenge(verifier: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(verifier);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return base64URLEncode(new Uint8Array(digest));
}

/**
 * Generate a random state string for CSRF protection
 * @returns Random state string
 */
export function generateState(): string {
  const array = new Uint8Array(16);
  crypto.getRandomValues(array);
  return base64URLEncode(array);
}

/**
 * Base64 URL encode a byte array
 * @param buffer Byte array to encode
 * @returns Base64 URL encoded string
 */
function base64URLEncode(buffer: Uint8Array): string {
  return btoa(String.fromCharCode(...buffer))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}
