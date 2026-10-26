/**
 * The data layer behind `/help`.
 *
 * The page a user opens is `/help`; the API it wraps is `/api/support/`, which
 * is why this module and its exports keep the support name. Anything that
 * names a destination a person can see says help, anything that names the
 * enterprise `platform_support` API says support.
 */
import { error, type Cookies } from '@sveltejs/kit';

import { apiRequest } from '#lib/api-helpers.js';
import { apiStatus } from '#lib/api-errors.js';

/**
 * The enterprise `platform_support` API's shapes (`SupportMessageSerializer`,
 * `SupportTicketListSerializer` and `SupportTicketDetailSerializer`); it is
 * not in the community schema. A list row has no `assigned`,
 * `first_response_at` or `messages`.
 */
type SupportMessage = {
  id: string;
  author_label: string;
  author_type: string;
  body: string;
  attachment_name: string;
  attachment_download_url: string | null;
  created_at: string;
};
type SupportTicket = {
  id: string;
  reference: string;
  subject: string;
  category: string;
  category_label: string;
  status: string;
  status_label: string;
  priority: string;
  priority_label: string;
  message_count?: number;
  last_activity_at: string;
  created_at: string;
  assigned?: boolean;
  first_response_at?: string | null;
  messages?: SupportMessage[];
};
type SupportTicketList = { count: number; tickets: SupportTicket[] };

export const SUPPORT_CATEGORIES = [
  { value: 'technical', label: 'Technical issue' },
  { value: 'billing', label: 'Billing' },
  { value: 'account', label: 'Account access' },
  { value: 'feature_request', label: 'Feature request' },
  { value: 'other', label: 'Other' }
];

function toMessage(message: SupportMessage, ticketId: string) {
  return {
    id: message.id,
    author: message.author_label,
    authorType: message.author_type,
    body: message.body ?? '',
    attachmentName: message.attachment_name || null,
    attachmentUrl: message.attachment_download_url
      ? `/help/${ticketId}/attachments/${message.id}`
      : null,
    createdAt: message.created_at
  };
}

function toTicket(ticket: SupportTicket) {
  return {
    id: ticket.id,
    reference: ticket.reference,
    subject: ticket.subject,
    category: ticket.category,
    categoryLabel: ticket.category_label,
    status: ticket.status,
    statusLabel: ticket.status_label,
    priority: ticket.priority,
    priorityLabel: ticket.priority_label,
    assigned: Boolean(ticket.assigned),
    messageCount: ticket.message_count ?? ticket.messages?.length ?? 0,
    firstResponseAt: ticket.first_response_at ?? null,
    lastActivityAt: ticket.last_activity_at,
    createdAt: ticket.created_at,
    messages: (ticket.messages ?? []).map((message) => toMessage(message, ticket.id))
  };
}

export async function listSupportTickets({ cookies }: { cookies: Cookies }) {
  const response: SupportTicketList = await apiRequest('/support/?limit=100', {}, { cookies });
  return {
    count: response.count ?? response.tickets?.length ?? 0,
    tickets: (response.tickets ?? []).map(toTicket)
  };
}

/**
 * Everything `/help` renders, and which of its two tiers to render.
 *
 * The self-serve half of that page is community code. The ticket queue behind
 * it is not: `/api/support/` is served by the enterprise `platform_support`
 * app, so a community deployment answers 404. A 404 therefore means "this
 * deployment has no support queue", not "something broke", and the page falls
 * back to the routes that do work. Anything else is rethrown, because an org
 * that does have support must see a real outage as an outage rather than be
 * quietly downgraded to the community page while their tickets sit unread.
 *
 * Lives here rather than in `+page.server.ts` so the vitest harness can reach
 * it. That harness resolves `#lib` and nothing else, and its include glob
 * cannot match a path containing `(app)` anyway, so a test placed next to the
 * route would never run. See the docstring in `vitest.config.js`.
 */
export async function loadHelpPage({ cookies }: { cookies: Cookies }) {
  try {
    return { available: true, ...(await listSupportTickets({ cookies })) };
  } catch (err) {
    if (apiStatus(err) !== 404) throw err;
    return { available: false, count: 0, tickets: [] };
  }
}

export async function getSupportTicket({ cookies }: { cookies: Cookies }, id: string) {
  if (!id) throw new Error('A support ticket id is required.');
  try {
    const ticket: SupportTicket = await apiRequest(
      `/support/${encodeURIComponent(id)}/`,
      {},
      { cookies }
    );
    return toTicket(ticket);
  } catch (err) {
    // On the status, not the wording. The API answers a ticket belonging to
    // somebody else with the same 404 as one that does not exist, which is
    // deliberate: a 403 here would confirm the id is real. Without this the
    // page answered 500, which every other v2 detail page already avoids.
    if (apiStatus(err) === 404) {
      error(404, 'That request does not exist, or somebody else opened it.');
    }
    throw err;
  }
}

/**
 * Create a ticket from a form while allow-listing every field. Organization,
 * requester, status, priority and assignee are deliberately impossible to
 * forward from this client, and the API rejects them too.
 */
export async function createSupportTicket(
  { cookies }: { cookies: Cookies },
  values: { subject: string; category: string; body: string; attachment?: File | null }
) {
  const body = new FormData();
  body.set('subject', values.subject.trim());
  body.set('category', values.category);
  body.set('body', values.body.trim());
  if (values.attachment?.size) body.set('attachment', values.attachment);
  const ticket: SupportTicket = await apiRequest(
    '/support/',
    { method: 'POST', body },
    { cookies }
  );
  return toTicket(ticket);
}

export async function replyToSupportTicket(
  { cookies }: { cookies: Cookies },
  id: string,
  values: { body: string; attachment?: File | null }
) {
  if (!id) throw new Error('A support ticket id is required.');
  const body = new FormData();
  body.set('body', values.body.trim());
  if (values.attachment?.size) body.set('attachment', values.attachment);
  const ticket: SupportTicket = await apiRequest(
    `/support/${encodeURIComponent(id)}/replies/`,
    { method: 'POST', body },
    { cookies }
  );
  return toTicket(ticket);
}
