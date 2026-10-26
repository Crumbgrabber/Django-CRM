import { error } from '@sveltejs/kit';
import { getRule, listRuns, RULE_GONE } from '#lib/server/v2/automation.js';
import { UUID } from '#lib/v2/custom-objects.js';
import { apiStatus } from '#lib/api-errors.js';
import type { PageServerLoad } from './$types';

/**
 * One rule's run history, a page at a time. The rule goes first so a member
 * is refused once, before any run is asked for.
 */
export const load: PageServerLoad = async (event) => {
  const { id } = event.params;
  if (!UUID.test(id)) error(404, RULE_GONE);
  const offset = Math.max(0, Number.parseInt(event.url.searchParams.get('offset') ?? '0', 10) || 0);
  try {
    const rule = await getRule(event, id);
    const page = await listRuns(event, id, offset);
    return { rule, ...page };
  } catch (err) {
    if (apiStatus(err) === 403) return { forbidden: true as const };
    throw err;
  }
};
