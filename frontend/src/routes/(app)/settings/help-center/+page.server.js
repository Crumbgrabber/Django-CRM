import { fail } from '@sveltejs/kit';
import {
  getHelpCenterSettings,
  saveErrorMessage,
  updateHelpCenterSettings
} from '#lib/server/v2/help-center-settings.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiStatus } from '#lib/api-errors.js';

/** @type {import('./$types').PageServerLoad} */
export async function load({ cookies }) {
  return { settings: await getHelpCenterSettings({ cookies }) };
}

/** @type {import('./$types').Actions} */
export const actions = {
  // Admin-only on the API. `can_edit` hides the form from a member, but that is
  // the affordance, not the check: `HelpCenterSettingsView.patch` refuses a
  // member whatever reaches it, and this turns that refusal into a sentence.
  async update(event) {
    const form = await event.request.formData();
    const values = {
      enabled: form.get('help_center_enabled') === 'true',
      slug: form.get('help_center_slug')?.toString() ?? ''
    };
    try {
      await updateHelpCenterSettings(event, values);
    } catch (err) {
      // One declared shape for both refusals, so the page's `values` survives
      // the union of the two.
      /** @type {{ error: string, values?: typeof values }} */
      const update =
        apiStatus(err) === 403
          ? { error: 'Only an admin can change the help center.' }
          : { error: saveErrorMessage(err, readableError), values };
      return fail(apiStatus(err) === 403 ? 403 : 400, { update });
    }
    return { updated: true };
  }
};
