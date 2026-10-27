import { redirect } from '@sveltejs/kit';
import { resolve } from '$app/paths';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = ({ url }) => {
  redirect(307, resolve('/(app)/campaigns') + url.search);
};
