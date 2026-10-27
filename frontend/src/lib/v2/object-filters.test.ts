import { describe, it, expect } from 'vitest';
import { objectDescriptor, objectSavedViewSpec } from './object-filters.js';
import { activeChips, fieldKeys } from './filters.js';
import { droppedValues, isShowing, pickFilters, viewHref } from './saved-views.js';

const FIELDS = [
  {
    key: 'kind',
    label: 'Kind',
    field_type: 'dropdown',
    options: [
      { value: 'flat', label: 'Flat' },
      { value: 'house', label: 'House' }
    ]
  },
  { key: 'pets', label: 'Pets allowed', field_type: 'checkbox' },
  { key: 'notes', label: 'Notes', field_type: 'text' },
  { key: 'beds', label: 'Bedrooms', field_type: 'number' },
  { key: 'listed', label: 'Listed', field_type: 'date' },
  { key: 'owner', label: 'Owner', field_type: 'link' },
  { key: 'old', label: 'Old', field_type: 'checkbox', is_active: false },
  { key: 'empty', label: 'Empty', field_type: 'dropdown', options: [] }
];

describe('objectDescriptor', () => {
  it('offers assignee, tags, then a filter per active dropdown and checkbox', () => {
    expect(objectDescriptor(FIELDS).fields.map((f) => [f.key, f.type])).toEqual([
      ['assigned_to', 'person'],
      ['tags', 'tag'],
      ['cf_kind', 'select'],
      ['cf_pets', 'boolean']
    ]);
  });

  it('turns dropdown options into choices with their labels', () => {
    const kind = objectDescriptor(FIELDS).fields.find((f) => f.key === 'cf_kind');
    expect(kind?.options).toEqual(['flat', 'house']);
    expect(kind?.labelFor?.('flat')).toBe('Flat');
    expect(kind?.labelFor?.('gone')).toBe('gone');
  });

  it('gives no filter for text, number, date, link, turned-off or option-less fields', () => {
    const keys = fieldKeys(objectDescriptor(FIELDS));
    for (const gone of ['cf_notes', 'cf_beds', 'cf_listed', 'cf_owner', 'cf_old', 'cf_empty']) {
      expect(keys).not.toContain(gone);
    }
  });

  it('reads a missing field list as no custom filters', () => {
    expect(fieldKeys(objectDescriptor(undefined))).toEqual(['assigned_to', 'tags']);
  });

  it('names a boolean chip Yes or No and a dropdown chip by its label', () => {
    const url = new URL('http://app.test/objects/property?cf_pets=false&cf_kind=house');
    const chips = activeChips(objectDescriptor(FIELDS), url as never);
    expect(chips.map((c) => [c.label, c.value])).toEqual([
      ['Kind', 'House'],
      ['Pets allowed', 'No']
    ]);
  });
});

describe('objectSavedViewSpec', () => {
  const spec = objectSavedViewSpec(FIELDS);

  it('saves the search, assignee, tags and custom filters, and repeats the first two lists', () => {
    expect(spec.keys).toEqual(['q', 'assigned_to', 'tags', 'cf_kind', 'cf_pets']);
    expect(spec.multi).toEqual(['assigned_to', 'tags']);
  });

  it('round trips through a view', () => {
    const params = new URLSearchParams('q=elm&tags=t1&tags=t2&cf_pets=true&page=3&cf_notes=x');
    const filters = pickFilters(params as never, spec);
    expect(filters).toEqual({ q: ['elm'], tags: ['t1', 't2'], cf_pets: ['true'] });
    expect(viewHref(new URL('http://app.test/objects/property') as never, filters, spec)).toBe(
      '/objects/property?q=elm&tags=t1&tags=t2&cf_pets=true'
    );
  });

  it('counts a value the page would drop, so the view is not shown as the current one', () => {
    const id = '0b9f4c6e-3f0a-4a5b-9a77-1c2d3e4f5a6b';
    const kind = FIELDS.find((f) => f.field_type === 'dropdown')!;
    const option = (kind.options as { value: string }[])[0].value;
    const ok = { assigned_to: [id], [`cf_${kind.key}`]: [option], cf_pets: ['true'] };
    expect(droppedValues(ok, spec)).toBe(0);
    // A phone view saved with the literal Me, a removed option, a non-boolean.
    expect(droppedValues({ assigned_to: ['me'] }, spec)).toBe(1);
    expect(droppedValues({ cf_pets: ['maybe'] }, spec)).toBe(1);
    const params = new URLSearchParams('assigned_to=me');
    expect(isShowing(params as never, { assigned_to: ['me'] }, spec)).toBe(false);
  });

  it('counts a dropdown value holding a NUL as dropped', () => {
    expect(droppedValues({ cf_kind: ['a\u0000b'] }, spec)).toBe(1);
  });

  it('keeps a dropdown value that is no longer an option, uncounted and still showing', () => {
    const stale = { cf_kind: ['under_offer'] };
    expect(droppedValues(stale, spec)).toBe(0);
    const params = new URLSearchParams('cf_kind=under_offer');
    expect(isShowing(params as never, stale, spec)).toBe(true);
  });
});
