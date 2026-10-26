import { listGoals } from '#lib/server/v2/goals.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
  return await listGoals(event);
};
