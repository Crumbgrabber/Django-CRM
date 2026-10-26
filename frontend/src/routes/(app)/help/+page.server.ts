import { loadHelpPage } from '#lib/server/v2/support.js';
import type { PageServerLoad } from './$types';

/**
 * Help has two tiers and `loadHelpPage` decides which one. The decision lives
 * in the lib module rather than here so it is reachable by the test harness.
 */
export const load: PageServerLoad = async ({ cookies }) => {
  return loadHelpPage({ cookies });
};
