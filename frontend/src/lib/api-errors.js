/**
 * Reading a failed `apiRequest`. Its own module, apart from `api-helpers.js`,
 * because most tests mock that module with `apiRequest` alone: a helper living
 * there would be missing from the mock in every error path those tests cover.
 */

/**
 * The JSON body of a DRF error reply, as far as callers read it.
 *
 * @typedef {{ detail?: string, error?: unknown, errors?: unknown, non_field_errors?: unknown, message?: unknown, code?: unknown, [key: string]: unknown }} ApiErrorBody
 */

/**
 * What `apiRequest` throws for an error reply.
 *
 * @typedef {Error & { status: number, body: ApiErrorBody }} ApiError
 */

/**
 * The HTTP status a failed `apiRequest` carries, or undefined for any other
 * failure (a network error, a bug). It reads the property rather than checking
 * the class, so a test double such as `{ status: 404 }` reads the same.
 *
 * @param {unknown} err
 * @returns {number | undefined}
 */
export function apiStatus(err) {
  const status = /** @type {{ status?: unknown } | null | undefined} */ (err)?.status;
  return typeof status === 'number' ? status : undefined;
}

/**
 * The parsed error body a failed `apiRequest` carries, or undefined.
 *
 * @param {unknown} err
 * @returns {ApiErrorBody | undefined}
 */
export function apiErrorBody(err) {
  const body = /** @type {{ body?: unknown } | null | undefined} */ (err)?.body;
  return body && typeof body === 'object' ? /** @type {ApiErrorBody} */ (body) : undefined;
}
