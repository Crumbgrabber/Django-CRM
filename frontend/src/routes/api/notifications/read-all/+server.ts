import { apiRequest } from '#lib/api-helpers.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async ({ request, cookies, locals }) => {
  let body: Record<string, unknown> = {};
  try {
    body = await request.json();
  } catch {
    // An empty or invalid body means there are no filters to forward.
  }
  await apiRequest(
    `/notifications/read-all/`,
    { method: 'POST', body },
    { cookies, org: locals?.org }
  );
  return new Response(null, { status: 204 });
};
