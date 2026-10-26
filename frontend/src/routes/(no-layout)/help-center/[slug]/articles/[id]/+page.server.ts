/**
 * One public help article. Every kind of miss (no such address, help center
 * switched off, draft, another org's article, malformed id) is the same 404.
 */

import { canonicalSlug, getHelpArticle } from '#lib/server/help-center.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
  const slug = canonicalSlug(event.params.slug, event.url);
  const data = await getHelpArticle(event, slug, event.params.id);
  return {
    slug,
    canonical: `${event.url.origin}/help-center/${slug}/articles/${data.article.id}`,
    ...data
  };
};
