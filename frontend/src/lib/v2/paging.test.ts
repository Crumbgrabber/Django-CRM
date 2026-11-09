import { describe, expect, it } from 'vitest';
import { pageLinks } from './paging.js';

const base = { limit: 25, count: 1992 };

describe('pageLinks', () => {
  it('first page has Next only', () => {
    const l = pageLinks('/contacts', '', { ...base, offset: 0, shown: 25 });
    expect([l.from, l.to, l.prev, l.next]).toEqual([1, 25, null, '/contacts?offset=25']);
  });
  it('second page goes back to a clean url and keeps filters', () => {
    const l = pageLinks('/contacts', 'search=a&offset=25', { ...base, offset: 25, shown: 25 });
    expect(l.prev).toBe('/contacts?search=a');
    expect(l.next).toBe('/contacts?search=a&offset=50');
    expect([l.from, l.to]).toEqual([26, 50]);
  });
  it('last page (1992 = 79 full pages + 17) has no Next', () => {
    const l = pageLinks('/contacts', 'offset=1975', { ...base, offset: 1975, shown: 17 });
    expect([l.from, l.to, l.next]).toEqual([1976, 1992, null]);
    expect(l.prev).toBe('/contacts?offset=1950');
  });
  it('size links reset the offset and keep the search', () => {
    const l = pageLinks('/contacts', 'search=a&offset=50', { ...base, offset: 50, shown: 25 });
    expect(l.size(100)).toBe('/contacts?search=a&limit=100');
  });
  it('exact fit has no Next; empty list shows 0-0', () => {
    expect(pageLinks('/x', '', { limit: 25, count: 25, offset: 0, shown: 25 }).next).toBeNull();
    const e = pageLinks('/x', '', { limit: 25, count: 0, offset: 0, shown: 0 });
    expect([e.from, e.to, e.prev, e.next]).toEqual([0, 0, null, null]);
  });
});
