import { listProjects, FILTER_FIELDS } from '#lib/server/v2/projects.js';
import { readFilters, buildFilterQuery } from '#lib/server/v2/filter-params.js';
import { getOrgPeopleAndTeams, resolveMe } from '#lib/server/v2/org-people.js';
import { listAccountsPicker } from '#lib/server/v2/accounts.js';
import type { PageServerLoad } from './$types';

/**
 * The projects the caller may see, newest first: every one for an admin,
 * otherwise the ones they created or are on. Filters live in the URL
 * (`readFilters` drops any value the descriptor does not allow) and `q`
 * searches the name.
 */
export const load: PageServerLoad = async (event) => {
  const { url, locals } = event;
  const params = buildFilterQuery(FILTER_FIELDS, readFilters(url, 'projects'));
  const q = (url.searchParams.get('q') ?? '').trim().slice(0, 200);
  if (q) params.set('search', q);

  const [{ results, totals }, orgPeople, accounts] = await Promise.all([
    listProjects(event, params),
    getOrgPeopleAndTeams(event.cookies),
    // The Account filter's options only; the list stands without them.
    listAccountsPicker(event).catch(() => ({ accounts: [] }))
  ]);

  return {
    projects: results,
    totals,
    q,
    people: orgPeople.people,
    accounts: accounts.accounts,
    meId: resolveMe(orgPeople.people, locals.user?.email)
  };
};
