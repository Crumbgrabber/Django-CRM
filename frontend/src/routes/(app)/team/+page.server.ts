import { fail } from '@sveltejs/kit';
import {
  listTeam,
  createTeam,
  deleteTeam,
  setTeamMembers,
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
  createTeam: async ({ cookies, request }) => {
    const form = await request.formData();
    const name = form.get('name')?.toString().trim();
    const description = form.get('description')?.toString().trim() || '';
    if (!name) return fail(400, { error: 'Enter a team name.' });
    try {
      await createTeam({ cookies }, name, description);
    } catch (err) {
      return fail(apiStatus(err) === 403 ? 403 : 400, {
        error: readableError(err, 'Could not create that team.')
      });
    }
    return { message: 'Team created.' };
  },
  deleteTeam: async ({ cookies, request }) => {
    const form = await request.formData();
    const teamId = form.get('teamId')?.toString();
    if (!teamId) return fail(400, { error: 'Choose a team.' });
    try {
      await deleteTeam({ cookies }, teamId);
    } catch (err) {
      return fail(apiStatus(err) === 403 ? 403 : 400, {
        error: readableError(err, 'Could not delete that team.')
      });
    }
    return { message: 'Team deleted.' };
  },
  /**
   * One Save for every team: per team the form sends `name:<id>`, the ticked
   * `member:<id>` values and `original:<id>` (comma-joined), so only teams
   * whose membership changed are written.
   */
  setMembers: async ({ cookies, request }) => {
    const form = await request.formData();
    const teamIds = form.getAll('teamId').map((id) => id.toString());
    if (!teamIds.length) return fail(400, { error: 'Choose a named team.' });
    const changes = [];
    for (const teamId of teamIds) {
      const name = form.get(`name:${teamId}`)?.toString().trim();
      if (!name) return fail(400, { error: 'Choose a named team.' });
      const profileIds = form.getAll(`member:${teamId}`).map((id) => id.toString());
      const original = (form.get(`original:${teamId}`)?.toString() || '')
        .split(',')
        .filter(Boolean);
      const same =
        original.length === profileIds.length && profileIds.every((id) => original.includes(id));
      if (!same) changes.push({ teamId, name, profileIds });
    }
    let saved = 0;
    for (const { teamId, name, profileIds } of changes) {
      try {
        await setTeamMembers({ cookies }, teamId, name, profileIds);
        saved += 1;
      } catch (err) {
        return fail(apiStatus(err) === 403 ? 403 : 400, {
          error: `${readableError(err, `Could not save members of ${name}.`)} (${saved} of ${changes.length} teams saved.)`
        });
      }
    }
    return { message: changes.length ? 'Team members saved.' : 'No membership changes to save.' };
  },
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

  /** Edit account and org contact fields. Role has its own action. */
  edit: async ({ cookies, request }) => {
    const form = await request.formData();
    const userId = form.get('userId')?.toString();
    const email = form.get('email')?.toString().trim();
    const name = form.get('name')?.toString().trim();
    const password = form.get('password')?.toString();
    if (!userId) return fail(400, { edit: { userId, error: 'Choose a person.' } });
    const contact: { phone?: string; alternate_phone?: string } = {};
    for (const field of ['phone', 'alternate_phone'] as const) {
      if (form.has(field)) contact[field] = form.get(field)?.toString().trim() ?? '';
    }

    try {
      await updateUser({ cookies }, userId, {
        ...contact,
        ...(email !== undefined && email !== form.get('originalEmail') ? { email } : {}),
        ...(name !== undefined && name !== form.get('originalName') ? { name } : {}),
        ...(password ? { password } : {})
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
