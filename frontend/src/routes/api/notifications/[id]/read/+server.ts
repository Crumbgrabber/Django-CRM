import { apiRequest } from '#lib/api-helpers.js';
import type { RequestHandler } from './$types';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const POST: RequestHandler = async ({ params, cookies, locals }) => {
  if (!UUID_RE.test(params.id)) return new Response(null, { status: 400 });
  await apiRequest(
    `/notifications/${params.id}/read/`,
    { method: 'POST' },
    { cookies, org: locals?.org }
  );
  return new Response(null, { status: 204 });
};
