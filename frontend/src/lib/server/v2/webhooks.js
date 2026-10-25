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

/** @typedef {import('#lib/api-schema.js').components['schemas']} Schemas */

/** Deliveries per page on an endpoint's log. */
export const DELIVERY_PAGE = 20;

/** The fields an admin edits. Nothing else is ever sent. */
const EDITABLE = ['url', 'description', 'events', 'format', 'is_active'];

/** @param {Record<string, unknown>} values */
export function buildBody(values) {
  /** @type {Record<string, unknown>} */
  const body = {};
  for (const key of EDITABLE) {
    if (values[key] !== undefined) body[key] = values[key];
  }
  return body;
}

/**
 * The checked event boxes on a create or edit form.
 * @param {FormData} form
 */
export function eventsFromForm(form) {
  return form
    .getAll('events')
    .map((v) => v.toString())
    .filter(Boolean);
}

/**
 * @param {{ cookies: import('@sveltejs/kit').Cookies }} event
 * @returns {Promise<{ forbidden: true } | { forbidden: false, endpoints: Schemas['WebhookEndpoint'][], catalogue: Schemas['WebhookEventGroup'][], limit: number }>}
 */
export async function listWebhooks({ cookies }) {
  /** @type {Schemas['WebhookListResponse']} */
  let resp;
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

/**
 * One endpoint, the catalogue for its edit form, and a page of deliveries.
 * @param {{ cookies: import('@sveltejs/kit').Cookies }} event
 * @param {string} id
 * @param {number} offset
 */
export async function getWebhook({ cookies }, id, offset = 0) {
  /** @type {Promise<Schemas['WebhookEndpoint']>} */
  const endpointRead = apiRequest(`/webhooks/${id}/`, {}, { cookies });
  /** @type {Promise<Schemas['WebhookListResponse']>} */
  const listRead = apiRequest('/webhooks/', {}, { cookies });
  /** @type {Promise<Schemas['WebhookDeliveryListResponse']>} */
  const deliveriesRead = apiRequest(
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

/**
 * @param {{ cookies: import('@sveltejs/kit').Cookies }} event @param {Record<string, unknown>} values
 * @returns {Promise<Schemas['WebhookEndpointCreated']>}
 */
export async function createWebhook({ cookies }, values) {
  return apiRequest('/webhooks/', { method: 'POST', body: buildBody(values) }, { cookies });
}

/**
 * @param {{ cookies: import('@sveltejs/kit').Cookies }} event
 * @param {string} id
 * @param {Record<string, unknown>} values
 * @returns {Promise<Schemas['WebhookEndpoint']>}
 */
export async function updateWebhook({ cookies }, id, values) {
  return apiRequest(`/webhooks/${id}/`, { method: 'PATCH', body: buildBody(values) }, { cookies });
}

/**
 * @param {{ cookies: import('@sveltejs/kit').Cookies }} event @param {string} id
 * @returns {Promise<null>}
 */
export async function deleteWebhook({ cookies }, id) {
  return apiRequest(`/webhooks/${id}/`, { method: 'DELETE' }, { cookies });
}

/**
 * @param {{ cookies: import('@sveltejs/kit').Cookies }} event
 * @param {string} id
 * @returns {Promise<Schemas['WebhookDelivery']>}
 */
export async function testWebhook({ cookies }, id) {
  return apiRequest(`/webhooks/${id}/test/`, { method: 'POST' }, { cookies });
}

/**
 * @param {{ cookies: import('@sveltejs/kit').Cookies }} event @param {string} id
 * @returns {Promise<Schemas['WebhookRotateSecretResponse']>}
 */
export async function rotateWebhookSecret({ cookies }, id) {
  return apiRequest(`/webhooks/${id}/rotate-secret/`, { method: 'POST' }, { cookies });
}

/**
 * @param {{ cookies: import('@sveltejs/kit').Cookies }} event
 * @param {string} deliveryId
 * @returns {Promise<Schemas['WebhookDelivery']>}
 */
export async function redeliverWebhook({ cookies }, deliveryId) {
  return apiRequest(
    `/webhooks/deliveries/${deliveryId}/redeliver/`,
    { method: 'POST' },
    { cookies }
  );
}
