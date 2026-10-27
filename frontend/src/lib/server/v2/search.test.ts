import { describe, it, expect, vi } from 'vitest';

vi.mock('#lib/api-helpers.js', () => ({ apiRequest: vi.fn() }));

const { paletteHit } = await import('#lib/server/v2/search.js');

const ID = '0b9f4c6e-3f0a-4a5b-9a77-1c2d3e4f5a6b';

describe('paletteHit', () => {
  it('maps a custom record hit to its record page under its group', () => {
    expect(
      paletteHit({
        type: 'obj:property',
        id: ID,
        title: '12 Elm Street',
        subtitle: 'Property',
        group: 'Properties'
      })
    ).toEqual({
      kind: 'Properties',
      id: ID,
      title: '12 Elm Street',
      meta: 'Property',
      href: `/objects/property/${ID}`
    });
  });

  it('keeps the built-in label when an older API sends no group', () => {
    expect(paletteHit({ type: 'lead', id: ID, title: 'Ada', subtitle: 'Acme' })).toEqual({
      kind: 'Leads',
      id: ID,
      title: 'Ada',
      meta: 'Acme',
      href: `/leads/${ID}`
    });
  });

  it('prefers the server group for a built-in hit', () => {
    expect(
      paletteHit({ type: 'deal', id: ID, title: 'D', subtitle: '', group: 'Deals' })?.kind
    ).toBe('Deals');
  });

  it('drops a hit of an unknown type or with a bad key or id', () => {
    expect(paletteHit({ type: 'widget', id: ID, title: 'x', subtitle: '' })).toBeNull();
    expect(paletteHit({ type: 'obj:Bad Key', id: ID, title: 'x', subtitle: '' })).toBeNull();
    expect(paletteHit({ type: 'obj:property', id: 'nope', title: 'x', subtitle: '' })).toBeNull();
  });
});
