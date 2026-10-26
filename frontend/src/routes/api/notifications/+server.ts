import { apiRequest } from '#lib/api-helpers.js';
import type { components } from '#lib/api-schema.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ url, cookies, locals }) => {
  const limit = url.searchParams.get('limit') || '20';
  const unread = url.searchParams.get('unread');
  const since = url.searchParams.get('since');
  const qs = new URLSearchParams({ limit });
  if (unread) qs.set('unread', unread);
  if (since) qs.set('since', since);
  const data: components['schemas']['NotificationListResponse'] = await apiRequest(
    `/notifications/?${qs.toString()}`,
    {},
    { cookies, org: locals?.org }
  );
  return Response.json(data);
};
