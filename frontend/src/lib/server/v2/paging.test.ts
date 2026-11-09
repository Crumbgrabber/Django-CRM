import { describe, expect, it } from 'vitest';
import { readPaging, withPaging } from './paging.js';
import { contactListQuery } from './list-queries.js';

const url = (q: string) => new URL(`http://x/contacts?${q}`);

describe('readPaging', () => {
  it('defaults to the first page of 25', () => {
    expect(readPaging(url(''))).toEqual({ limit: 25, offset: 0 });
  });
  it('clamps junk', () => {
    expect(readPaging(url('limit=100000&offset=-5'))).toEqual({ limit: 25, offset: 0 });
    expect(readPaging(url('limit=abc&offset=abc'))).toEqual({ limit: 25, offset: 0 });
  });
  it('accepts the offered sizes', () => {
    expect(readPaging(url('limit=100&offset=200'))).toEqual({ limit: 100, offset: 200 });
  });
});

describe('list queries', () => {
  it('forwards offset and limit for contacts', () => {
    const p = contactListQuery(url('search=a&limit=50&offset=50'));
    expect(p.get('offset')).toBe('50');
    expect(p.get('limit')).toBe('50');
    expect(p.get('search')).toBe('a');
  });
  it('withPaging drops a zero offset', () => {
    expect(withPaging(new URLSearchParams('offset=9'), url('')).has('offset')).toBe(false);
  });
});
