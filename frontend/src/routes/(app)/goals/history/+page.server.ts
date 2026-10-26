import { getGoalHistory } from '#lib/server/v2/goals.js';
import type { PageServerLoad } from './$types';

/**
 * Attainment across finished periods.
 *
 * Open to any member; the endpoint narrows a non-admin to their own goals and
 * their teams' with the same predicate the list and the leaderboard use, so
 * there is nothing to gate here.
 */
export const load: PageServerLoad = async (event) => {
  return await getGoalHistory(event);
};
