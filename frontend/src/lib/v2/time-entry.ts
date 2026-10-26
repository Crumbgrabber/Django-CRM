/**
 * Whether a time entry is billed. `invoiced` stays true while Invoices is
 * switched off, when `invoice` is emptied; an older answer carries only `invoice`.
 */
export function isBilled(
  entry: { invoiced?: boolean; invoice?: unknown } | null | undefined
): boolean {
  return entry?.invoiced === true || entry?.invoice != null;
}

type EntryLink = { id?: string; name?: string | null };

/**
 * What an entry was logged on: its ticket or its project, or null for an
 * entry whose project was deleted (both links are then null). The timesheet
 * expands `case` to `{ id, name }`; other reads give the bare id.
 */
export function entryParent(
  entry:
    | {
        case?: string | EntryLink | null;
        project?: string | EntryLink | null;
        project_name?: string | null;
      }
    | null
    | undefined
): { kind: 'ticket' | 'project'; id: string; name: string; href: string } | null {
  const ticket = entry?.case;
  if (ticket) {
    const id = typeof ticket === 'object' ? ticket.id : ticket;
    if (typeof id === 'string' && id) {
      const name = (typeof ticket === 'object' && ticket.name) || 'A ticket';
      return { kind: 'ticket', id, name, href: `/tickets/${id}` };
    }
  }
  const project = entry?.project;
  const projectId = project && typeof project === 'object' ? project.id : project;
  if (typeof projectId === 'string' && projectId) {
    const name =
      entry?.project_name ||
      (project && typeof project === 'object' && project.name) ||
      'A project';
    return { kind: 'project', id: projectId, name, href: `/projects/${projectId}` };
  }
  return null;
}

/**
 * The entries a bill of time can take: stopped, billable and not yet billed.
 * The API refuses any other, and a set in more than one currency.
 */
export function unbilledEntries(
  entries:
    | Array<{
        id: string;
        ended_at?: string | null;
        billable?: boolean;
        duration_minutes?: number | string | null;
        currency?: string | null;
        invoiced?: boolean;
        invoice?: unknown;
      }>
    | null
    | undefined
): { ids: string[]; minutes: number; currencies: string[] } {
  const ready = (entries ?? []).filter((e) => e?.ended_at && e.billable && !isBilled(e));
  return {
    ids: ready.map((e) => e.id),
    minutes: ready.reduce((sum, e) => sum + (Number(e.duration_minutes) || 0), 0),
    currencies: [...new Set(ready.flatMap((e) => (e.currency ? [e.currency] : [])))].sort()
  };
}

/**
 * A report row's billable share as a whole percentage, or null with no time.
 * Taken from the API's `billable_share` where it sends one; an older API
 * sends only the minutes, so the share is worked out from them.
 */
export function billableSharePercent(row: {
  billable_share?: number | string | null;
  billable_minutes?: number;
  total_minutes?: number;
}): number | null {
  if (row?.billable_share !== undefined) {
    if (row.billable_share === null) return null;
    const share = Number(row.billable_share);
    return Number.isFinite(share) ? Math.round(share * 100) : null;
  }
  const total = Number(row?.total_minutes) || 0;
  if (!total) return null;
  return Math.round(((Number(row?.billable_minutes) || 0) / total) * 100);
}
