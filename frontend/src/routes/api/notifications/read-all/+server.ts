import { apiRequest } from '#lib/api-helpers.js';
import type { components } from '#lib/api-schema.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async ({ request, cookies, locals }) => {
  let before: string | undefined;
  try {
    const value = ((await request.json()) as { before?: unknown } | null)?.before;
    if (typeof value === 'string') before = value;
  } catch {
    // An empty or invalid body means there are no filters to forward.
  }
  const body: components['schemas']['NotificationReadAllRequestRequest'] = before ? { before } : {};
  await apiRequest(
    `/notifications/read-all/`,
    { method: 'POST', body },
    { cookies, org: locals?.org }
  );
  return new Response(null, { status: 204 });
};
