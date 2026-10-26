/**
 * Reading a failed `apiRequest`. Its own module, apart from `api-helpers.js`,
 * because most tests mock that module with `apiRequest` alone: a helper living
 * there would be missing from the mock in every error path those tests cover.
 */

/** The JSON body of a DRF error reply, as far as callers read it. */
export type ApiErrorBody = {
  detail?: string;
  error?: unknown;
  errors?: unknown;
  non_field_errors?: unknown;
  message?: unknown;
  code?: unknown;
  [key: string]: unknown;
};

/** What `apiRequest` throws for an error reply. */
export type ApiError = Error & { status: number; body: ApiErrorBody };

/**
 * The HTTP status a failed `apiRequest` carries, or undefined for any other
 * failure (a network error, a bug). It reads the property rather than checking
 * the class, so a test double such as `{ status: 404 }` reads the same.
 */
export function apiStatus(err: unknown): number | undefined {
  const status = (err as { status?: unknown } | null | undefined)?.status;
  return typeof status === 'number' ? status : undefined;
}

/** The parsed error body a failed `apiRequest` carries, or undefined. */
export function apiErrorBody(err: unknown): ApiErrorBody | undefined {
  const body = (err as { body?: unknown } | null | undefined)?.body;
  return body && typeof body === 'object' ? (body as ApiErrorBody) : undefined;
}
