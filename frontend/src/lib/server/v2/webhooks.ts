/**
 * Outbound webhooks: the wiring behind `/settings/webhooks`.
 *
 * Server-only. A webhook's signing secret passes through here twice in its
 * life (the create response and a rotate response) and is handed to the page
 * for that one render. Nothing here stores or logs it.
 *
 * ADMIN-ONLY, READS INCLUDED
 * `webhooks/views.py` answers a member 403 on every route, the list too: a
 * hook URL is often a bearer credential of its own (Zapier and Slack both put
 * the secret in the path), and the delivery log holds copies of records. So
 * the list folds a 403 into `forbidden`, the shape `listOrgTokens` uses, and
 * the page says "Admins only" instead of crashing.
 *
 * WHAT A WRITE MAY CARRY
 * `buildBody` is an allow-list. The secret is minted by the server and the
 * serializer refuses a body that names one; `org` comes from the JWT.
 */
import { apiRequest } from '#lib/api-helpers.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

/** Deliveries per page on an endpoint's log. */
export const DELIVERY_PAGE = 20;

/** The fields an admin edits. Nothing else is ever sent. */
const EDITABLE = ['url', 'description', 'events', 'format', 'is_active'];

export function buildBody(values: Record<string, unknown>) {
  const body: Record<string, unknown> = {};
  for (const key of EDITABLE) {
    if (values[key] !== undefined) body[key] = values[key];
  }
  return body;
}

/** The checked event boxes on a create or edit form. */
export function eventsFromForm(form: FormData) {
  return form
    .getAll('events')
    .map((v) => v.toString())
    .filter(Boolean);
}

export async function listWebhooks({ cookies }: { cookies: Cookies }): Promise<
  | { forbidden: true }
  | {
      forbidden: false;
      endpoints: Schemas['WebhookEndpoint'][];
      catalogue: Schemas['WebhookEventGroup'][];
      limit: number;
    }
> {
  let resp: Schemas['WebhookListResponse'];
  try {
    resp = await apiRequest('/webhooks/', {}, { cookies });
  } catch (err) {
    if (apiStatus(err) === 403) return { forbidden: true };
    throw err;
  }
  return {
    forbidden: false,
    endpoints: resp?.endpoints ?? [],
    catalogue: resp?.event_catalogue ?? [],
    limit: resp?.limit ?? 0
  };
}

/** One endpoint, the catalogue for its edit form, and a page of deliveries. */
export async function getWebhook({ cookies }: { cookies: Cookies }, id: string, offset = 0) {
  const endpointRead: Promise<Schemas['WebhookEndpoint']> = apiRequest(
    `/webhooks/${id}/`,
    {},
    { cookies }
  );
  const listRead: Promise<Schemas['WebhookListResponse']> = apiRequest(
    '/webhooks/',
    {},
    { cookies }
  );
  const deliveriesRead: Promise<Schemas['WebhookDeliveryListResponse']> = apiRequest(
    `/webhooks/${id}/deliveries/?limit=${DELIVERY_PAGE}&offset=${offset}`,
    {},
    { cookies }
  );
  const [endpoint, list, deliveries] = await Promise.all([endpointRead, listRead, deliveriesRead]);
  return {
    endpoint,
    catalogue: list?.event_catalogue ?? [],
    deliveries: deliveries?.results ?? [],
    deliveryCount: deliveries?.count ?? 0,
    offset,
    pageSize: DELIVERY_PAGE
  };
}

export async function createWebhook(
  { cookies }: { cookies: Cookies },
  values: Record<string, unknown>
): Promise<Schemas['WebhookEndpointCreated']> {
  return apiRequest('/webhooks/', { method: 'POST', body: buildBody(values) }, { cookies });
}

export async function updateWebhook(
  { cookies }: { cookies: Cookies },
  id: string,
  values: Record<string, unknown>
): Promise<Schemas['WebhookEndpoint']> {
  return apiRequest(`/webhooks/${id}/`, { method: 'PATCH', body: buildBody(values) }, { cookies });
}

export async function deleteWebhook({ cookies }: { cookies: Cookies }, id: string): Promise<null> {
  return apiRequest(`/webhooks/${id}/`, { method: 'DELETE' }, { cookies });
}

export async function testWebhook(
  { cookies }: { cookies: Cookies },
  id: string
): Promise<Schemas['WebhookDelivery']> {
  return apiRequest(`/webhooks/${id}/test/`, { method: 'POST' }, { cookies });
}

export async function rotateWebhookSecret(
  { cookies }: { cookies: Cookies },
  id: string
): Promise<Schemas['WebhookRotateSecretResponse']> {
  return apiRequest(`/webhooks/${id}/rotate-secret/`, { method: 'POST' }, { cookies });
}

export async function redeliverWebhook(
  { cookies }: { cookies: Cookies },
  deliveryId: string
): Promise<Schemas['WebhookDelivery']> {
  return apiRequest(
    `/webhooks/deliveries/${deliveryId}/redeliver/`,
    { method: 'POST' },
    { cookies }
  );
}
