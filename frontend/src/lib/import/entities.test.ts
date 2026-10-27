import { describe, it, expect } from 'vitest';
import { objectImportConfig, objectImportTargets } from './entities.js';

const DEF = {
  key: 'property',
  label: 'Property',
  label_plural: 'Properties',
  name_label: 'Address',
  fields: [
    { key: 'beds', label: 'Bedrooms', field_type: 'number' },
    {
      key: 'kind',
      label: 'Kind',
      field_type: 'dropdown',
      options: [{ value: 'flat', label: 'Flat' }]
    },
    { key: 'pets', label: 'Pets allowed', field_type: 'checkbox' },
    { key: 'owner', label: 'Owner', field_type: 'link' },
    { key: 'old', label: 'Old', field_type: 'text', is_active: false }
  ]
};

describe('objectImportTargets', () => {
  it('is the name, each active non-link field, then assignees and tags', () => {
    expect(objectImportTargets(DEF)).toEqual([
      { name: 'name', label: 'Address' },
      { name: 'beds', label: 'Bedrooms' },
      { name: 'kind', label: 'Kind' },
      { name: 'pets', label: 'Pets allowed' },
      { name: 'assigned_to', label: 'Assigned to' },
      { name: 'tags', label: 'Tags' }
    ]);
  });

  it('is just the name, assignees and tags for an object with no fields', () => {
    expect(objectImportTargets({ ...DEF, fields: undefined }).map((t) => t.name)).toEqual([
      'name',
      'assigned_to',
      'tags'
    ]);
  });
});

describe('objectImportTargets reserved keys', () => {
  it('never offers a field keyed name, assigned_to, tags or full_name as a target', () => {
    const fields = ['name', 'assigned_to', 'tags', 'full_name', 'beds'].map((key) => ({
      key,
      label: `L ${key}`,
      field_type: 'text'
    }));
    const names = objectImportTargets({ ...DEF, fields }).map((t) => t.name);
    expect(names).toEqual(['name', 'beds', 'assigned_to', 'tags']);
  });
});

describe('objectImportConfig', () => {
  const config = objectImportConfig(DEF);

  it('heads the template with the name label, the field labels, Assigned to and Tags', () => {
    expect(config.templateHeaders).toEqual([
      'Address',
      'Bedrooms',
      'Kind',
      'Pets allowed',
      'Assigned to',
      'Tags'
    ]);
  });

  it('gives one example cell per header, shaped by field type', () => {
    expect(config.templateExample).toEqual([
      'Example property',
      '3',
      'Flat',
      'Yes',
      'agent@yourco.com',
      'vip,featured'
    ]);
    expect(config.templateExample).toHaveLength(config.templateHeaders.length);
  });

  it("posts to the object's own list page and names its downloads by key", () => {
    expect(config).toMatchObject({
      actionPath: '/objects/property',
      listHref: '/objects/property',
      fileStem: 'property',
      singular: 'property',
      plural: 'properties'
    });
  });
});
