import { mergeRoute } from '#lib/server/v2/duplicates.js';
import type { Actions, PageServerLoad } from './$types';

/** Side by side with `?with=<id>`, then merge. See `mergeRoute`. */
const route = mergeRoute('accounts');

export const load: PageServerLoad = route.load;

export const actions: Actions = route.actions;
