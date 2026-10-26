import { error, fail, redirect } from '@sveltejs/kit';
import {
  getCatalogue,
  getRule,
  listRules,
  updateRule,
  ruleFromForm,
  refusedSave,
  tryRule,
  switchOff,
  deleteRule,
  RULE_GONE
} from '#lib/server/v2/automation.js';
import { UUID } from '#lib/v2/custom-objects.js';
import { checkId } from '#lib/server/v2/custom-objects.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiErrorBody, apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';

const RECORD_GONE = 'That record does not exist, or you cannot open it.';

function sentence(err: unknown, fallback: string) {
  const detail = apiErrorBody(err)?.detail;
  return typeof detail === 'string' ? detail : readableError(err, fallback);
}

function statusOf(err: unknown) {
  const status = apiStatus(err);
  return status !== undefined && Number.isInteger(status) && status >= 400 && status < 600
    ? status
    : 400;
}

/**
 * The rule beside its row from the list, since only the list computes a
 * status. The list goes first so a member is refused once, not three times.
 */
export const load: PageServerLoad = async (event) => {
  const { id } = event.params;
  if (!UUID.test(id)) error(404, RULE_GONE);
  const list = await listRules(event);
  if (list.forbidden) return { forbidden: true as const };
  const [catalogue, rule] = await Promise.all([getCatalogue(event), getRule(event, id)]);
  const row = (list.rules ?? []).find((r) => r.id === rule.id) ?? null;
  return { catalogue, rule, row };
};

export const actions: Actions = {
  async save(event) {
    const { id } = event.params;
    if (!UUID.test(id)) return fail(400, { save: { general: RULE_GONE, rows: {} } });
    const form = await event.request.formData();
    try {
      const body = ruleFromForm(form, { create: false });
      if (form.get('switch_on') === 'true') body.is_active = true;
      await updateRule(event, id, body);
    } catch (err) {
      return refusedSave(err);
    }
    return { saved: true };
  },

  /** Plans the saved rule on one record; nothing is written. */
  async try(event) {
    const { id } = event.params;
    if (!UUID.test(id)) return fail(404, { tryError: RULE_GONE });
    const form = await event.request.formData();
    const recordId = form.get('record_id');
    const name = form.get('record_name');
    let record: string;
    try {
      record = checkId(recordId);
    } catch {
      return fail(404, { tryError: RECORD_GONE });
    }
    try {
      const steps = await tryRule(event, id, record);
      const recordName = typeof name === 'string' ? name.trim().slice(0, 120) : '';
      return { tried: { recordName, steps } };
    } catch (err) {
      if (apiStatus(err) === 404) return fail(404, { tryError: RECORD_GONE });
      return fail(statusOf(err), { tryError: sentence(err, 'Could not try the rule.') });
    }
  },

  async switchOff(event) {
    const { id } = event.params;
    if (!UUID.test(id)) return fail(400, { switchOff: { general: RULE_GONE } });
    try {
      await switchOff(event, id);
    } catch (err) {
      return fail(statusOf(err), {
        switchOff: { general: sentence(err, 'Could not switch the rule off.') }
      });
    }
    return { switchedOff: true };
  },

  async remove(event) {
    const { id } = event.params;
    if (!UUID.test(id)) return fail(400, { remove: { general: RULE_GONE } });
    try {
      await deleteRule(event, id);
    } catch (err) {
      return fail(statusOf(err), {
        remove: { general: sentence(err, 'Could not delete the rule.') }
      });
    }
    redirect(303, '/settings/automation');
  }
};
