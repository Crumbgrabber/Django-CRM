/**
 * Public help center switch: the wiring behind `/settings/help-center`.
 *
 * Server-only. `GET /org/help-center/` answers any member with the switch, the
 * address, the public URL and `can_edit`, which the API derives from the
 * caller's role (admins and superusers). `PATCH` is admin-only there; `can_edit`
 * decides what this page offers, never what it is allowed to do.
 */
import { apiRequest } from '#lib/api-helpers.js';
import { apiErrorBody } from '#lib/api-errors.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

/** Both verbs answer this. */
type HelpCenterState = components['schemas']['HelpCenterSettingsRead'];

export async function getHelpCenterSettings({
  cookies
}: {
  cookies: Cookies;
}): Promise<HelpCenterState> {
  return apiRequest('/org/help-center/', {}, { cookies });
}

/**
 * Save the switch and the address together.
 *
 * Exactly two keys reach the API, so a hostile form field (`org`, `id`,
 * `is_active`) is dropped here as well as ignored there. The slug is sent as
 * typed apart from surrounding spaces: lowercasing, the format rule, reserved
 * words and uniqueness are the serializer's, so the message a person reads
 * comes from the one place the rule lives.
 */
export async function updateHelpCenterSettings(
  { cookies }: { cookies: Cookies },
  { enabled, slug }: { enabled: boolean; slug: string }
): Promise<HelpCenterState> {
  return apiRequest(
    '/org/help-center/',
    {
      method: 'PATCH',
      body: { help_center_enabled: Boolean(enabled), help_center_slug: String(slug ?? '').trim() }
    },
    { cookies }
  );
}

/**
 * What to tell the person whose save was refused.
 *
 * Every rule the serializer applies to this form is about the address, so its
 * message is read straight off `help_center_slug` ("That address is already
 * taken. Choose another.") rather than through `readableError`, which would
 * prefix it with the raw field name.
 *
 * @param err the error `apiRequest` threw
 */
export function saveErrorMessage(
  err: unknown,
  readableError: (err: unknown, fallback: string) => string
) {
  const slugErrors = apiErrorBody(err)?.help_center_slug;
  if (Array.isArray(slugErrors) && slugErrors.length) return String(slugErrors[0]);
  return readableError(err, 'Could not save the help center.');
}
