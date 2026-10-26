/**
 * Approval rules: the wiring behind `/settings/ticket-approvals`.
 *
 * Server-only. Reads `GET /cases/approval-rules/`, the rules that gate a ticket
 * close and who can clear them. Each rule carries its match conditions, the
 * approver role / named approvers, and a backend-computed `pending_count` (the
 * Approval rows in state "pending" bound to it). Totals carry `count`, `active`,
 * and `pending` (the org's total waiting approvals).
 *
 * Create, edit, turn off, turn on and delete are wired below. Delete is not
 * what its name says on this resource: it destroys a rule that has never been
 * used and turns off one that has, and it answers 2xx either way. See
 * `deleteApprovalRule` for how the two are told apart.
 *
 * The backend
 * returns `approvers` as `[{ id, email }]`; that shape is kept as-is rather than
 * flattened to bare email strings, because the edit form needs the ids to
 * preselect the approver multi-select. The page reads `.email` off each entry
 * for the sentence it renders on the row.
 */
import { apiRequest, type FormBody } from '#lib/api-helpers.js';
import { viewerIsAdmin } from './organization.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];
export type ApprovalRuleRow = Awaited<ReturnType<typeof getApprovalRules>>['rules'][number];

export async function getApprovalRules({ cookies }: { cookies: Cookies }) {
  const { rules, totals }: Schemas['ApprovalRuleListResponse'] = await apiRequest(
    '/cases/approval-rules/',
    {},
    { cookies }
  );
  return {
    rules: (rules ?? []).map((r) => ({
      id: r.id,
      name: r.name,
      is_active: r.is_active,
      approver_role: r.approver_role,
      approvers: (r.approvers ?? []).filter((a) => a && a.id),
      match_priority: r.match_priority,
      match_case_type: r.match_case_type,
      match_team: r.match_team ?? null,
      pending_count: r.pending_count ?? 0,
      // Not displayed. It is the tie-break `find_matching_rule` uses between
      // rules with identical conditions, so it is what lets the page tell an
      // older duplicate (which can never run) from a fallback. See
      // `../../routes/(app)/settings/ticket-approvals/matching.js`.
      created_at: r.created_at ?? null
    })),
    totals: totals ?? { count: 0, active: 0, pending: 0 },
    // A display hint: POST/PUT/DELETE on `/cases/approval-rules/` each start
    // with `_is_admin(request.profile)` server-side and 403 regardless of
    // what this says. This only decides whether the page offers the controls.
    can_edit: viewerIsAdmin(cookies)
  };
}

/** Everything a create or edit may set. `org` and `created_by` are the JWT's,
 *  never the body's, and `trigger_event` is not here: see `TRIGGER_EVENT`
 *  below. Nothing is frozen after creation on this resource, so an edit may
 *  set the same fields a create may; `ApprovalRuleDetailView.put` builds its
 *  serializer with `partial=True`, so an omitted key is left untouched rather
 *  than blanked, which is what lets the turn-on action send a single key. */
const CREATE_FIELDS: (keyof Schemas['ApprovalRuleRequest'])[] = [
  'name',
  'match_priority',
  'match_case_type',
  'match_team_id',
  'approver_role',
  'approver_ids',
  'is_active'
];
const UPDATE_FIELDS = CREATE_FIELDS;

/** The only value `trigger_event` accepts. It is set here rather than read
 *  from the form: a select with one option is a control that cannot be
 *  wrong, so it should not be a control. If the backend ever gains a second
 *  trigger, this is the one line that has to change and the field becomes a
 *  real select. */
const TRIGGER_EVENT = 'pre_close';

type RuleValues = { [key: string]: unknown; approver_ids?: unknown[] };

function buildBody(allowed: typeof CREATE_FIELDS, values: RuleValues) {
  const body: FormBody<Schemas['ApprovalRuleRequest']> = {};
  for (const field of allowed) {
    if (values[field] === undefined) continue;
    body[field] = values[field];
  }
  // Three nullable fields whose "any" option is an empty `<option>` value.
  // `''` fails the ChoiceField and the PK lookup alike; `null` is what clears
  // them, and all three are `allow_null=True`.
  for (const nullable of ['match_priority', 'match_case_type', 'match_team_id'] as const) {
    if (body[nullable] === '') body[nullable] = null;
  }
  if (body.is_active !== undefined) body.is_active = Boolean(body.is_active);
  if (body.approver_ids !== undefined) {
    body.approver_ids = (values.approver_ids ?? []).filter(Boolean);
  }
  return body;
}

export async function createApprovalRule(
  { cookies }: { cookies: Cookies },
  values: RuleValues
): Promise<Schemas['ApprovalRule']> {
  const body = buildBody(CREATE_FIELDS, values);
  if (!body.name) throw new Error('A rule needs a name.');
  body.trigger_event = TRIGGER_EVENT;
  return await apiRequest('/cases/approval-rules/', { method: 'POST', body }, { cookies });
}

export async function updateApprovalRule(
  { cookies }: { cookies: Cookies },
  id: string,
  values: RuleValues
): Promise<Schemas['ApprovalRule']> {
  if (!id) throw new Error('Which rule? No rule id was given.');
  const body = buildBody(UPDATE_FIELDS, values);
  return await apiRequest(`/cases/approval-rules/${id}/`, { method: 'PUT', body }, { cookies });
}

/**
 * Delete a rule, or turn it off, depending on what the backend decides.
 *
 * There IS a soft-delete hiding behind this verb, and an earlier version of
 * this comment said the opposite. `ApprovalRuleDetailView.delete` branches:
 *
 * ```python
 * if rule.requests.exists():
 *     rule.is_active = False
 *     rule.save(update_fields=["is_active", "updated_at"])
 *     return Response({"id": str(rule.id), "is_active": False}, status=200)
 * rule.delete()
 * ```
 *
 * `Approval.rule` is `on_delete=models.PROTECT`, so a rule that has ever gated
 * a close cannot be destroyed without taking the approval history with it. The
 * view turns it off instead and still answers 2xx, so the caller cannot read
 * the outcome off "did it throw".
 *
 * Two things make the outcome unguessable from the page's own data:
 *
 * - `rule.requests.exists()` counts approvals in EVERY state. The
 *   `pending_count` the page already has counts only `state="pending"`, so a
 *   rule showing zero pending can still have history and still be soft
 *   disabled.
 * - The two branches differ only in their body. `apiRequest` returns the
 *   parsed body on 200 and `null` on the hard-delete branch's 204, so
 *   `is_active === false` in the response is the signal, and the absence of a
 *   body is the other one.
 *
 * Hence the return shape: the action that calls this reports what happened
 * rather than asserting what it hoped for.
 *
 * @returns `turned_off` is true when the
 *   rule had history and was disabled rather than destroyed.
 */
export async function deleteApprovalRule(
  { cookies }: { cookies: Cookies },
  id: string
): Promise<{ turned_off: boolean }> {
  if (!id) throw new Error('Which rule? No rule id was given.');
  const resp: Schemas['ApprovalRuleDeactivatedResponse'] | null = await apiRequest(
    `/cases/approval-rules/${id}/`,
    { method: 'DELETE' },
    { cookies }
  );
  return { turned_off: resp?.is_active === false };
}
