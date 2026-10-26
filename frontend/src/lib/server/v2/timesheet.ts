/**
 * Time entries: the wiring behind /v2/timesheet and the ticket's time panel.
 * A project's time panel is in `projects.js` and builds its bodies here.
 *
 * Server-only. `GET /time-entries/timesheet/` returns the caller's own week
 * grouped into day buckets (every day present, empty or not) with week
 * totals, the billable split, and a running-timer count. The page reads it
 * verbatim as `data.week`.
 *
 * The v2 timesheet page is always "your timesheet", it has no profile
 * switcher, so this layer never passes a `profile`, which also keeps it clear
 * of the endpoint's admin-only "another profile" 403. `TimesheetView` already
 * expands `case` and `invoice` to `{id, name}` / `{id, invoice_number}` and
 * names the profile, so there is no reshaping here.
 *
 * The rest is the ticket panel's surface, ticket-scoped on the way in
 * (`/cases/<id>/time-entries/`) and entry-scoped on the way back out
 * (`/time-entries/<id>/`), which is how the API splits it. Every write lands
 * here rather than in `tickets.js` so one file holds what the app knows about
 * time entries; `stopTimer` is shared by both callers already.
 *
 * None of these check who owns an entry. The API does: it narrows a list to
 * the caller's own rows for a non-admin, and answers 403 on someone else's
 * entry. Nothing below should be read as having re-checked that.
 */
import { apiRequest, type FormBody } from '#lib/api-helpers.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

/**
 * The caller's timesheet for a Mon..Sun week, shaped for the page.
 *
 * With no explicit week the range is left off and the API picks this week in
 * the org's timezone. Computing it here would take UTC's week, which is last
 * week for a Monday morning east of UTC.
 *
 * @param range explicit week; the API needs both ends
 */
export async function getTimesheet(
  { cookies }: { cookies: Cookies },
  { start, end }: { start?: string; end?: string } = {}
): Promise<{ week: Schemas['Timesheet'] }> {
  const qs = start && end ? `?${new URLSearchParams({ start, end }).toString()}` : '';
  const week: Schemas['Timesheet'] = await apiRequest(
    `/time-entries/timesheet/${qs}`,
    {},
    { cookies }
  );
  return { week };
}

/**
 * Stop a running timer.
 *
 * The id guard is not defensive noise: an empty id would POST to
 * `/time-entries//stop/`, which is a different path, and the failure would
 * read as a routing bug rather than a missing argument.
 *
 * Ownership is the backend's call. The endpoint is org-scoped and checks the
 * entry belongs to the caller, so this does not re-check it here and must not
 * be read as having done so.
 *
 * @returns the stopped entry
 */
export async function stopTimer(
  { cookies }: { cookies: Cookies },
  entryId: string
): Promise<Schemas['TimeEntry']> {
  if (!entryId) throw new Error('Which time entry? No entry id was given.');

  return await apiRequest(`/time-entries/${entryId}/stop/`, { method: 'POST' }, { cookies });
}

/** Longest manual entry the form will send, in minutes. A day of work logged
 *  in one go is already unusual; more than that is a typo, and the API has no
 *  ceiling of its own to catch it. */
const MAX_ENTRY_MINUTES = 1440;

/** The groupings `/time-entries/report/` accepts. `project` only while Projects is on. */
export const REPORT_GROUPINGS = ['agent', 'ticket', 'project', 'account'];

/**
 * Where the time went over a window: totals by agent, ticket, project or
 * account.
 *
 * `group_by` and `billable` are checked against what the API accepts rather
 * than forwarded blind. Both arrive from the query string, so a hand-edited
 * URL would otherwise turn a 400 into a 500 page; an unknown value falls back
 * to the default instead, which is what the filter bar shows anyway. An API
 * without projects refuses `group_by=project`, so `projectsOn` false drops it
 * the same way.
 *
 * The window is passed through as given (YYYY-MM-DD, inclusive). Left off, the
 * API answers for the last 30 days and says which days those were, so the page
 * never has to guess a range it did not choose.
 */
export async function getTimeReport(
  { cookies }: { cookies: Cookies },
  filters: {
    start?: string;
    end?: string;
    group_by?: string;
    billable?: string;
    account?: string;
    profile?: string;
    project?: string;
  } = {},
  { projectsOn = true }: { projectsOn?: boolean } = {}
): Promise<{ report: Schemas['TimeReport'] }> {
  const groupings = projectsOn ? REPORT_GROUPINGS : REPORT_GROUPINGS.filter((g) => g !== 'project');
  const qs = new URLSearchParams();
  if (filters.start) qs.set('start', filters.start);
  if (filters.end) qs.set('end', filters.end);
  qs.set(
    'group_by',
    groupings.includes(filters.group_by ?? '') ? String(filters.group_by) : 'agent'
  );
  if (filters.billable === 'true' || filters.billable === 'false') {
    qs.set('billable', filters.billable);
  }
  if (filters.account) qs.set('account', filters.account);
  if (filters.profile) qs.set('profile', filters.profile);
  if (projectsOn && filters.project) qs.set('project', filters.project);

  const report: Schemas['TimeReport'] = await apiRequest(
    `/time-entries/report/?${qs.toString()}`,
    {},
    { cookies }
  );
  return { report };
}

/**
 * Every time entry on one ticket, newest first.
 *
 * Returns the array as given. An agent sees only their own rows here and an
 * admin sees the team's, which is the API's decision, not this layer's, so
 * the panel must not present the total it can add up from this list as the
 * ticket's total. `time_summary` on the ticket is that number.
 */
export async function listTicketTime(
  { cookies }: { cookies: Cookies },
  ticketId: string
): Promise<Schemas['TimeEntry'][]> {
  if (!ticketId) throw new Error('Which ticket? No ticket id was given.');

  const entries: Schemas['TimeEntry'][] = await apiRequest(
    `/cases/${ticketId}/time-entries/`,
    {},
    { cookies }
  );
  return Array.isArray(entries) ? entries : [];
}

/**
 * Start a running timer on a ticket.
 *
 * The API answers 409 when this person already has one running, anywhere, and
 * names the ticket it is on. That id is carried through on the thrown error so
 * the page can offer a way to it: "you have a timer running" with no way to
 * reach it is a dead end on the one screen that could fix it.
 *
 * @returns the started entry
 */
export async function startTicketTimer(
  { cookies }: { cookies: Cookies },
  ticketId: string
): Promise<Schemas['TimeEntry']> {
  if (!ticketId) throw new Error('Which ticket? No ticket id was given.');

  return await apiRequest(
    `/cases/${ticketId}/time-entries/start/`,
    { method: 'POST' },
    { cookies }
  );
}

/**
 * Log a stopped entry after the fact.
 *
 * The API wants two timestamps; the form asks for one duration, so the window
 * is built here as "the last `minutes` minutes", ending now. That is what the
 * phone does too (`mobile/lib/widgets/tickets/ticket_time_panel.dart`), and it
 * keeps the clock out of the browser's hands: a UTC instant computed on the
 * server cannot be a day out because somebody's laptop is set wrong.
 *
 * It also means an entry cannot be backdated to last Tuesday from here. That
 * is the same limit the phone has, and adding a date field would need a
 * timezone to resolve it against, which a `<input type="date">` does not send.
 *
 * `description` is required by `TimeEntryCreateSerializer` and checked here
 * too, so an empty box is answered without a round trip. `currency` is the
 * org's, passed in by the caller: left off, every entry would be USD and an
 * org that invoices in euros could not bill a single one of them, since the
 * invoice builder refuses a mixed-currency set.
 *
 * @returns the created entry
 */
export async function logTicketTime(
  { cookies }: { cookies: Cookies },
  ticketId: string,
  entry: {
    minutes: number | string;
    description: string;
    billable?: boolean;
    hourlyRate?: string | number | null;
    currency?: string | null;
  }
): Promise<Schemas['TimeEntry']> {
  if (!ticketId) throw new Error('Which ticket? No ticket id was given.');

  return await apiRequest(
    `/cases/${ticketId}/time-entries/`,
    { method: 'POST', body: loggedEntryBody(entry) },
    { cookies }
  );
}

/**
 * The body for a stopped entry logged after the fact, on a ticket or a
 * project: the last `minutes` minutes, ending now (see `logTicketTime`).
 * Throws a sentence for the form when the input will not do.
 */
export function loggedEntryBody(entry: {
  minutes: number | string;
  description: string;
  billable?: boolean;
  hourlyRate?: string | number | null;
  currency?: string | null;
}): FormBody<Schemas['TimeEntryCreateRequest']> {
  const minutes = Number(entry.minutes);
  if (!Number.isInteger(minutes) || minutes < 1 || minutes > MAX_ENTRY_MINUTES) {
    throw new Error(`Minutes must be a whole number between 1 and ${MAX_ENTRY_MINUTES}.`);
  }
  const description = (entry.description ?? '').trim();
  if (!description) throw new Error('Say what the time was spent on.');

  const ended = new Date();
  const started = new Date(ended.getTime() - minutes * 60000);

  const body: FormBody<Schemas['TimeEntryCreateRequest']> = {
    started_at: started.toISOString(),
    ended_at: ended.toISOString(),
    description,
    billable: Boolean(entry.billable)
  };

  // Optional, and only when it is a number the API will take. A rate is the
  // difference between an invoice line worth something and one worth 0.00.
  if (entry.hourlyRate !== null && entry.hourlyRate !== undefined && entry.hourlyRate !== '') {
    const rate = Number(entry.hourlyRate);
    if (!Number.isFinite(rate) || rate < 0) throw new Error('The rate must be a positive number.');
    body.hourly_rate = rate.toFixed(2);
  }
  if (entry.currency) body.currency = entry.currency;
  return body;
}

/**
 * Flip one entry between billable and not.
 *
 * A PUT carrying the single field. The endpoint updates partially, so the
 * description, the window, and the rate are left where they are; sending the
 * whole entry back would race anyone editing it elsewhere.
 *
 * @returns the updated entry
 */
export async function setEntryBillable(
  { cookies }: { cookies: Cookies },
  entryId: string,
  billable: boolean
): Promise<Schemas['TimeEntry']> {
  if (!entryId) throw new Error('Which time entry? No entry id was given.');

  return await apiRequest(
    `/time-entries/${entryId}/`,
    { method: 'PUT', body: { billable: Boolean(billable) } },
    { cookies }
  );
}

/**
 * Delete an entry.
 *
 * The API refuses one that has been invoiced, which is the check that matters
 * and is not repeated here: an entry can be invoiced between this page
 * rendering and the button being pressed, so the answer has to come from the
 * server either way.
 */
export async function deleteEntry(
  { cookies }: { cookies: Cookies },
  entryId: string
): Promise<null> {
  if (!entryId) throw new Error('Which time entry? No entry id was given.');

  return await apiRequest(`/time-entries/${entryId}/`, { method: 'DELETE' }, { cookies });
}
