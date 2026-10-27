import { describe, it, expect } from 'vitest';
import { objectListQuery } from './object-list.js';

const FIELDS = [
  {
    key: 'kind',
    label: 'Kind',
    field_type: 'dropdown',
    options: [{ value: 'flat', label: 'Flat' }]
  },
  { key: 'pets', label: 'Pets', field_type: 'checkbox' },
  { key: 'beds', label: 'Bedrooms', field_type: 'number' }
];
const ID = '0b9f4c6e-3f0a-4a5b-9a77-1c2d3e4f5a6b';
const ID2 = '1c9f4c6e-3f0a-4a5b-9a77-1c2d3e4f5a6c';
const url = (qs: string) => new URL(`http://app.test/objects/property?${qs}`);

describe('objectListQuery', () => {
  it('forwards q, repeated assignees and tags, and the typed custom filters', () => {
    const q = objectListQuery(
      url(`q=%20elm%20&assigned_to=${ID}&assigned_to=${ID2}&tags=${ID}&cf_kind=flat&cf_pets=true`),
      FIELDS
    );
    expect(q.getAll('assigned_to')).toEqual([ID, ID2]);
    expect(q.getAll('tags')).toEqual([ID]);
    expect(q.get('cf_kind')).toBe('flat');
    expect(q.get('cf_pets')).toBe('true');
    expect(q.get('q')).toBe('elm');
  });

  it('drops a malformed id, a non-boolean and unknown or paging params', () => {
    const q = objectListQuery(
      url('assigned_to=me&tags=x&cf_pets=maybe&cf_beds=3&cf_nope=1&limit=500&page=2'),
      FIELDS
    );
    expect([...q]).toEqual([]);
  });

  it('keeps a dropdown value that is no longer an option and sends it on', () => {
    expect(objectListQuery(url('cf_kind=castle'), FIELDS).getAll('cf_kind')).toEqual(['castle']);
  });

  it('drops a dropdown value holding a NUL instead of sending it to the API', () => {
    expect(objectListQuery(url('cf_kind=a%00b'), FIELDS).getAll('cf_kind')).toEqual([]);
  });

  it('caps a long search at 100 characters', () => {
    expect(objectListQuery(url(`q=${'a'.repeat(300)}`), FIELDS).get('q')).toHaveLength(100);
  });
});
