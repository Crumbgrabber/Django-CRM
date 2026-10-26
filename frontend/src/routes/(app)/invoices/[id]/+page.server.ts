import { fail, redirect, type ActionFailure } from '@sveltejs/kit';
import {
  getInvoice,
  sendInvoice,
  markInvoicePaid,
  cancelInvoice,
  duplicateInvoice,
  updateInvoiceFields
} from '#lib/server/v2/invoices.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiStatus } from '#lib/api-errors.js';
import { readCustomFields, saveRefusal } from '#lib/server/v2/record-custom-fields.js';
import type { Actions, PageServerLoad } from './$types';

/** One invoice, with its line items. */
export const load: PageServerLoad = async ({ cookies, params, url }) => {
  const invoice = await getInvoice({ cookies }, params.id);
  return { ...invoice, editFields: url.searchParams.get('fields') === 'edit' };
};

export const actions: Actions = {
  /**
   * The "Edit fields" form: sends `custom_fields` and nothing else. Annotated
   * so the refusal that echoes `values` is not folded into the bare one.
   */
  fields: async ({
    cookies,
    params,
    request
  }): Promise<
    ActionFailure<{
      fieldsError: string;
      fieldErrors: Record<string, string>;
      values?: { custom_fields: Record<string, string | boolean | null> };
    }>
  > => {
    const form = await request.formData();
    const custom = await readCustomFields(cookies, 'Invoice', form);
    if (custom.refusal) return fail(503, { fieldsError: custom.refusal.error, fieldErrors: {} });
    if (custom.values) {
      try {
        await updateInvoiceFields({ cookies }, params.id, custom.values);
      } catch (err) {
        const { error, fieldErrors } = saveRefusal(
          err,
          custom.definitions,
          'Could not save these fields.'
        );
        return fail(apiStatus(err) === 404 ? 404 : 400, {
          fieldsError: error,
          fieldErrors,
          values: { custom_fields: custom.values }
        });
      }
    }
    redirect(303, `/invoices/${params.id}`);
  },

  /** Send it, or re-send an overdue one. 400 if it is Paid or Cancelled. */
  send: async ({ cookies, params }) => {
    try {
      await sendInvoice({ cookies }, params.id);
    } catch (err) {
      return fail(apiStatus(err) === 404 ? 404 : 400, {
        error: readableError(err, 'Could not send this invoice.')
      });
    }
    return { sent: true };
  },

  /**
   * Record a payment. An empty amount settles the whole balance; a figure takes
   * a partial payment, which the API validates against what is still owed.
   */
  markPaid: async ({ cookies, params, request }) => {
    const form = await request.formData();
    const amount = form.get('amount')?.toString().trim() ?? '';
    const reference = form.get('reference_number')?.toString().trim() ?? '';
    try {
      await markInvoicePaid(
        { cookies },
        params.id,
        amount ? { amount, reference_number: reference } : { reference_number: reference }
      );
    } catch (err) {
      return fail(apiStatus(err) === 404 ? 404 : 400, {
        error: readableError(err, 'Could not record that payment.')
      });
    }
    return { paid: true };
  },

  /** Cancel it. 400 if already Cancelled, or if Paid. Settled money stays. */
  cancel: async ({ cookies, params }) => {
    try {
      await cancelInvoice({ cookies }, params.id);
    } catch (err) {
      return fail(apiStatus(err) === 404 ? 404 : 400, {
        error: readableError(err, 'Could not cancel this invoice.')
      });
    }
    return { cancelled: true };
  },

  /**
   * Copy to a fresh Draft and open it. The new invoice's id comes back from the
   * API, so the redirect lands on the copy rather than reloading the original.
   */
  duplicate: async ({ cookies, params }) => {
    let created;
    try {
      created = await duplicateInvoice({ cookies }, params.id);
    } catch (err) {
      return fail(apiStatus(err) === 404 ? 404 : 400, {
        error: readableError(err, 'Could not duplicate this invoice.')
      });
    }
    const newId = created?.invoice?.id;
    if (newId) redirect(303, `/invoices/${newId}`);
    return { duplicated: true };
  }
};
