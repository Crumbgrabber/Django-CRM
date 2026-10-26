import { fail, redirect } from '@sveltejs/kit';
import { deleteAccount, getAccount } from '#lib/server/v2/accounts.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiStatus } from '#lib/api-errors.js';
import { loadRelated, relatedActions } from '#lib/server/v2/related-records.js';
import { recordDuplicates } from '#lib/server/v2/duplicates.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ cookies, params }) => {
  const [account, duplicates, related] = await Promise.all([
    getAccount({ cookies }, params.id),
    recordDuplicates({ cookies }, 'accounts', params.id),
    loadRelated({ cookies }, 'account', params.id)
  ]);
  return { ...account, duplicates, related };
};

export const actions: Actions = {
  ...relatedActions('account'),
  /**
   * Delete this account. The API applies the delete rule and answers 403 or 404
   * when it refuses, and 409 while invoices still point at the account; the page shows its sentence. On success the account is
   * gone, so the list is where to land.
   */
  delete: async ({ cookies, params }) => {
    try {
      await deleteAccount({ cookies }, params.id);
    } catch (err) {
      const status = apiStatus(err);
      const code = status !== undefined && status >= 400 && status < 500 ? status : 400;
      return fail(code, { deleteError: readableError(err, 'Could not delete this account.') });
    }
    redirect(303, '/accounts');
  }
};
