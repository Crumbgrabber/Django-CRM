import { listProducts } from '#lib/server/v2/products.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
  // The page reads `data.products` (the shape the fixture loader used); the data
  // layer returns the rows as `results`, so rename here and pass the rest through.
  const { results, totals, can_manage } = await listProducts(event);
  return { products: results, totals, can_manage };
};
