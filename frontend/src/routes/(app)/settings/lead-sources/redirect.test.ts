import { expect, it, vi } from 'vitest';
vi.mock('$app/paths', () => ({ resolve: (path: string) => `/crm${path.replace(/\/\([^)]+\)/g, '')}` }));
const { load } = await import('./+page.server.js');
it.each(['', '?search=Spring%20fair&tag=a&tag=b'])('preserves query string %s', (search) => {
  expect(() =>
    load({ url: new URL(`http://test/settings/lead-sources${search}`) } as Parameters<
      typeof load
    >[0])
  ).toThrow(expect.objectContaining({ status: 307, location: `/crm/campaigns${search}` }));
});
