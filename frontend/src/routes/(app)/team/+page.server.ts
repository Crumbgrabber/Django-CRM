import { fail } from '@sveltejs/kit';
import {
  listTeam,
  inviteUser,
  updateUser,
  setRole,
  setStatus,
  isRole
} from '#lib/server/v2/team.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';

/**
 * Team and access.
 *
 * Server load, so the JWT cookie stays server-side. The list, the totals and
 * the per-person token counts all arrive from the real org; a non-admin gets
 * `forbidden` back rather than a broken page, because the underlying endpoints
 * are admin-only.
 */
export const load: PageServerLoad = async ({ cookies }) => {
  return await listTeam({ cookies });
};

export const actions: Actions = {
  /**
   * Add a member: email, role, and optionally a name and a password. The
   * server is the boundary. It gates this to admins, rejects a duplicate within
   * the org with a 400, and reuses an account that already exists elsewhere
   * (refusing a password for it) instead of erroring.
   */
  invite: async ({ cookies, request }) => {
    const form = await request.formData();
    const email = form.get('email')?.toString().trim();
    const role = form.get('role')?.toString() || 'USER';
    const name = form.get('name')?.toString().trim();
    const password = form.get('password')?.toString();
    if (!email) return fail(400, { invite: { error: 'Enter an email address.' } });
    if (!isRole(role)) return fail(400, { invite: { error: 'Pick a valid role.' } });

    try {
      await inviteUser({ cookies }, { email, role, name, password });
    } catch (err) {
      return fail(apiStatus(err) === 403 ? 403 : 400, {
        invite: {
          error:
            apiStatus(err) === 403
              ? 'Only an admin can add people.'
              : readableError(err, 'Could not add that person.')
        }
      });
    }
    return { invited: email };
  },

  /**
   * Edit a person's name, email, password and role. A blank password leaves it
   * as it is. Role is sent only for another person's row, as the server
   * ignores it on your own.
   */
  edit: async ({ cookies, request }) => {
    const form = await request.formData();
    const userId = form.get('userId')?.toString();
    const email = form.get('email')?.toString().trim();
    const name = form.get('name')?.toString().trim();
    const password = form.get('password')?.toString();
    const role = form.get('role')?.toString() || undefined;
    if (!userId || !email) return fail(400, { edit: { userId, error: 'Enter an email address.' } });
    if (role !== undefined && !isRole(role))
      return fail(400, { edit: { userId, error: 'Pick a valid role.' } });

    try {
      await updateUser({ cookies }, userId, {
        email,
        ...(name ? { name } : {}),
        ...(password ? { password } : {}),
        ...(role ? { role } : {})
      });
    } catch (err) {
      return fail(apiStatus(err) === 403 ? 403 : 400, {
        edit: {
          userId,
          error:
            apiStatus(err) === 403
              ? 'Only an admin can edit people.'
              : readableError(err, 'Could not save those changes.')
        }
      });
    }
    return { edited: userId };
  },

  /**
   * Change someone's role. The page only shows this control for another
   * person's row and never for the last admin, mirroring the server's rules,
   * but the server is what enforces them: a member cannot promote themselves
   * and nobody can change their own role here.
   */
  setRole: async ({ cookies, request }) => {
    const form = await request.formData();
    const userId = form.get('userId')?.toString();
    const role = form.get('role')?.toString();
    if (!userId || !role || !isRole(role)) {
      return fail(400, { error: 'Which person, and to what role?' });
    }
    try {
      await setRole({ cookies }, userId, role);
    } catch (err) {
      return fail(apiStatus(err) === 403 ? 403 : 400, {
        error:
          apiStatus(err) === 403
            ? 'That is not yours to change.'
            : readableError(err, 'Could not change that role.')
      });
    }
    return { roleChanged: userId };
  },

  /**
   * Activate or deactivate a member. The server refuses to deactivate the last
   * active admin (a 400), so the org can never be stranded without one.
   */
  setStatus: async ({ cookies, request }) => {
    const form = await request.formData();
    const userId = form.get('userId')?.toString();
    const status = form.get('status')?.toString();
    if (!userId || (status !== 'Active' && status !== 'Inactive')) {
      return fail(400, { error: 'Which person, and active or not?' });
    }
    try {
      await setStatus({ cookies }, userId, status);
    } catch (err) {
      return fail(apiStatus(err) === 403 ? 403 : 400, {
        error:
          apiStatus(err) === 403
            ? 'Only an admin can change who is active.'
            : readableError(err, 'Could not change that status.')
      });
    }
    return { statusChanged: userId };
  }
};
