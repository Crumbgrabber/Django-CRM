import { fail, redirect } from '@sveltejs/kit';
import { createInvoiceTemplate } from '#lib/server/v2/templates.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { isOrgAdmin } from '#lib/admin.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';

/**
 * Creating a template.
 *
 * Admin-only: `POST /api/invoices/templates/` refuses a non-admin via
 * `_forbid_non_admin_template`, so this mirrors the products/new and
 * goals/new pattern: `load` computes `can_manage` with `isOrgAdmin(locals.profile)`
 * (same source the list page's `load` already uses) so a non-admin who
 * navigates here directly sees an "admins only" state instead of a form the
 * POST would refuse. The list page's own button is gated the same way.
 */
export const load: PageServerLoad = ({ locals }) => {
  return { can_manage: isOrgAdmin(locals.profile) };
};

/**
 * Read only the fields this form owns. Anything else in the submission is
 * ignored here and would be dropped by the allow-list in the data layer too.
 */
function readValues(form: FormData) {
  return {
    name: form.get('name')?.toString() ?? '',
    primary_color: form.get('primary_color')?.toString() ?? '',
    secondary_color: form.get('secondary_color')?.toString() ?? '',
    default_notes: form.get('default_notes')?.toString() ?? '',
    default_terms: form.get('default_terms')?.toString() ?? '',
    footer_text: form.get('footer_text')?.toString() ?? '',
    is_default: form.get('is_default') === 'on'
  };
}

export const actions: Actions = {
  create: async ({ cookies, request }) => {
    const form = await request.formData();
    const logo = form.get('logo');
    const logoFile = logo instanceof File && logo.size > 0 ? logo : null;
    const values = readValues(form);

    try {
      await createInvoiceTemplate({ cookies }, values, logoFile);
    } catch (err) {
      return fail(apiStatus(err) === 403 ? 403 : 400, {
        values,
        error:
          apiStatus(err) === 403
            ? 'Only an admin can create an invoice template.'
            : readableError(err, 'Could not create the template.')
      });
    }

    redirect(303, '/invoices/templates');
  }
};
