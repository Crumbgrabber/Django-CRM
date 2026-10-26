import { fail, redirect } from '@sveltejs/kit';
import {
  addProjectNote,
  billProjectTime,
  deleteProject,
  getProject,
  getUnbilled,
  invoiceProjectAmount,
  listProjectTime,
  logProjectTime,
  startProjectTimer
} from '#lib/server/v2/projects.js';
import { deleteEntry, setEntryBillable, stopTimer } from '#lib/server/v2/timesheet.js';
import { listTasks } from '#lib/server/v2/tasks.js';
import { getModules } from '#lib/server/v2/modules.js';
import { fieldDefinitions, fieldsForDetail } from '#lib/server/v2/record-custom-fields.js';
import { commentAction } from '#lib/server/v2/record-notes.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiErrorBody, apiStatus } from '#lib/api-errors.js';
import { isOn } from '#lib/v2/modules.js';
import { isOrgAdmin } from '#lib/admin.js';
import { todayIn } from '#lib/v2/dates.js';
import { billGrouping, invoiceAmountBody, isoDateOrNull } from '#lib/v2/projects.js';
import type { Actions, PageServerLoad } from './$types';

/** A refusal's own 4xx status for `fail`, or 400 for anything else. */
function clientStatus(err: unknown) {
  const status = apiStatus(err);
  return status !== undefined && status >= 400 && status < 500 ? status : 400;
}

/**
 * One project: the record, its tasks and time, and the Bill time preview
 * while `?bill=1` is open (`&up_to=` picks the date, today in the org's zone
 * by default). The tasks and the time are their own reads and may fail
 * without the page: `null` means the read failed and the tab says so.
 *
 * A project's tasks come from the task list filtered by project, and are
 * checked here against the project too, so an API that ignored the filter
 * could not fill the tab with every task in the org.
 */
export const load: PageServerLoad = async (event) => {
  const { params, url, locals } = event;
  const modules = (await getModules(event))?.modules ?? null;
  const timesheetOn = isOn(modules, 'timesheet');
  const tasksOn = isOn(modules, 'tasks');
  const invoicesOn = isOn(modules, 'invoices');

  const [detail, entries, tasks, definitions] = await Promise.all([
    getProject(event, params.id),
    timesheetOn ? listProjectTime(event, params.id) : Promise.resolve(null),
    tasksOn
      ? listTasks(event, new URLSearchParams({ project: params.id, limit: '100' }))
          .then(({ results }) =>
            results.filter((t) => t.related?.kind === 'project' && t.related.id === params.id)
          )
          .catch(() => null)
      : Promise.resolve(null),
    fieldDefinitions(event.cookies, 'Project')
  ]);

  const timezone = locals.org_settings?.timezone || 'UTC';
  const billable = detail.project.billing_type !== 'non_billable';
  const bill = {
    open: url.searchParams.get('bill') === '1' && detail.canBill && invoicesOn && timesheetOn,
    upTo: isoDateOrNull(url.searchParams.get('up_to')) ?? todayIn(timezone),
    unbilled: null as Awaited<ReturnType<typeof getUnbilled>>
  };
  if (bill.open) bill.unbilled = await getUnbilled(event, params.id, bill.upTo);

  return {
    ...detail,
    customFields: fieldsForDetail(
      { custom_field_definitions: definitions },
      detail.project.custom_fields
    ),
    tasks,
    time: {
      entries,
      // Display-only: which running timer is this person's to stop. User
      // ids on both sides, as on the ticket panel.
      viewerUserId: locals.user?.id ?? null,
      now: new Date().toISOString()
    },
    on: { timesheet: timesheetOn, tasks: tasksOn, invoices: invoicesOn },
    offers: {
      billTime: detail.canBill && invoicesOn && timesheetOn && billable,
      invoiceAmount: detail.canBill && invoicesOn && detail.project.billing_type === 'fixed_fee'
    },
    bill,
    tab: url.searchParams.get('tab') ?? ''
  };
};

/**
 * The time-panel writes answer through `timeError`, the bill through
 * `billError`, so each message shows beside the control that was pressed.
 */
export const actions: Actions = {
  comment: commentAction(addProjectNote),

  delete: async (event) => {
    try {
      await deleteProject(event, event.params.id);
    } catch (err) {
      const code = clientStatus(err);
      return fail(code, { error: readableError(err, 'Could not delete this project.') });
    }
    redirect(303, '/projects');
  },

  /** One running timer per person: a 409 names where it is running. */
  startTimer: async (event) => {
    const form = await event.request.formData();
    try {
      await startProjectTimer(event, event.params.id, {
        task: form.get('task')?.toString() ?? '',
        billable: form.get('billable') === 'true'
      });
    } catch (err) {
      const body = apiErrorBody(err);
      return fail(apiStatus(err) === 409 ? 409 : 400, {
        timeError: readableError(err, 'Could not start the timer.'),
        runningTicketId: body?.running_case_id ?? null,
        runningProjectId: body?.running_project_id ?? null
      });
    }
    return { timeStarted: true };
  },

  stopTimer: async (event) => {
    const form = await event.request.formData();
    try {
      await stopTimer(event, form.get('entry_id')?.toString() ?? '');
    } catch (err) {
      return fail(400, { timeError: readableError(err, 'Could not stop the timer.') });
    }
    return { timeStopped: true };
  },

  logTime: async (event) => {
    const form = await event.request.formData();
    try {
      await logProjectTime(event, event.params.id, {
        minutes: form.get('minutes')?.toString() ?? '',
        description: form.get('description')?.toString() ?? '',
        billable: form.get('billable') === 'on',
        // Only an admin types a rate; the API ignores a member's anyway.
        hourlyRate: isOrgAdmin(event.locals.profile)
          ? (form.get('hourly_rate')?.toString() ?? '')
          : '',
        task: form.get('task')?.toString() ?? ''
      });
    } catch (err) {
      return fail(400, { timeError: readableError(err, 'Could not log this time.') });
    }
    return { timeLogged: true };
  },

  setBillable: async (event) => {
    const form = await event.request.formData();
    try {
      await setEntryBillable(
        event,
        form.get('entry_id')?.toString() ?? '',
        form.get('billable') === 'true'
      );
    } catch (err) {
      return fail(400, { timeError: readableError(err, 'Could not change this entry.') });
    }
    return { timeUpdated: true };
  },

  deleteTime: async (event) => {
    const form = await event.request.formData();
    try {
      await deleteEntry(event, form.get('entry_id')?.toString() ?? '');
    } catch (err) {
      return fail(400, { timeError: readableError(err, 'Could not delete this entry.') });
    }
    return { timeDeleted: true };
  },

  /** Admins only, by the API: a draft invoice of the unbilled time, then open it. */
  billTime: async (event) => {
    const form = await event.request.formData();
    let made: { invoice_id?: string };
    try {
      made = await billProjectTime(event, event.params.id, {
        upTo: form.get('up_to')?.toString() ?? '',
        groupBy: billGrouping(form.get('group_by')?.toString())
      });
    } catch (err) {
      const code = clientStatus(err);
      return fail(code, { billError: readableError(err, 'Could not bill this time.') });
    }
    redirect(303, made?.invoice_id ? `/invoices/${made.invoice_id}` : '/invoices');
  },

  /** Admins only, by the API: a one-line draft for part of a fixed fee. */
  invoiceAmount: async (event) => {
    const form = await event.request.formData();
    const budget = Number(form.get('budget_amount') ?? '');
    const { body, error } = invoiceAmountBody(
      {
        mode: form.get('mode')?.toString(),
        value: form.get('value')?.toString(),
        description: form.get('description')?.toString()
      },
      Number.isFinite(budget) && budget > 0 ? budget : null
    );
    if (!body) return fail(400, { amountError: error });
    let made: { invoice_id?: string };
    try {
      made = await invoiceProjectAmount(event, event.params.id, body);
    } catch (err) {
      const code = clientStatus(err);
      return fail(code, { amountError: readableError(err, 'Could not make that invoice.') });
    }
    redirect(303, made?.invoice_id ? `/invoices/${made.invoice_id}` : '/invoices');
  }
};
