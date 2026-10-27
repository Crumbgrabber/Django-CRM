/**
 * The write body for a custom object record, read off a submitted form.
 * Only what the form was built to send is read: the field lists come from the
 * object's definition, never from the form's own keys.
 */
import {
  collectFromForm,
  collectLinks,
  collectAssignees,
  collectTags,
  type FieldDefinition
} from '#lib/server/v2/record-fields.js';

type RecordBody = {
  name: string;
  custom_fields: Record<string, string | boolean | null>;
  links?: Record<string, string[]>;
  assigned_to?: string[];
  tags?: string[];
};

/** @param definition The object with its active fields. */
export function readRecordForm(
  form: FormData,
  definition: { fields?: Array<FieldDefinition & { is_active?: boolean }> }
): RecordBody {
  const fields = (definition.fields ?? []).filter((f) => f.is_active !== false);
  // Only the fields the form rendered are read, so a checkbox ticked after the page loaded is not overwritten.
  const rendered = new Set((form.get('cf__rendered')?.toString() ?? '').split(','));
  const plain = fields.filter((f) => f.field_type !== 'link' && rendered.has(f.key));
  const linkFields = fields.filter((f) => f.field_type === 'link');

  const body: RecordBody = {
    name: form.get('name')?.toString().trim() ?? '',
    custom_fields: collectFromForm(form, plain)
  };
  const links = collectLinks(form, linkFields);
  if (Object.keys(links).length > 0) body.links = links;
  const assignedTo = collectAssignees(form);
  if (assignedTo !== undefined) body.assigned_to = assignedTo;
  const tags = collectTags(form);
  if (tags !== undefined) body.tags = tags;
  return body;
}
