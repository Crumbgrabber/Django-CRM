/**
 * Editor logic for the automation builder. Browser-safe: pages and components
 * render from these helpers, and the catalogue is the only source of labels.
 */
import { runTime } from '#lib/v2/format.js';
import { isOn, OBJECT_MODULES, type ModuleRow } from '#lib/v2/modules.js';
import { budgetNotificationText, retainerInvoiceNotificationText } from '#lib/v2/projects.js';
import { estimateNotificationText } from '#lib/v2/estimates.js';
import type { Tone } from '#lib/v2/enums.js';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];
export type Catalogue = Schemas['AutomationCatalogueResponse'];
export type CatalogueObject = Schemas['AutomationCatalogueObject'];
export type Field = Schemas['AutomationCatalogueField'];
/** An object `set_field` can write to, which may be one the catalogue no longer lists. */
type TargetObject = Omit<CatalogueObject, 'label_plural'>;
export type Option = {
  value: string;
  label: string;
  group?: string;
  settable?: boolean;
  gone?: boolean;
};

/**
 * The rule language, as `backend/automation/validation.py` accepts it. A
 * value is text, a number, a date or choice as text, true or false, a member
 * id, or a list of them; null on a trigger or condition means none.
 */
export type RuleValue = string | number | boolean | null | Array<string | number | boolean>;
type RuleTrigger = { event: string; field?: string | null; to?: RuleValue };
export type RuleCondition = { field: string; op: string; value: RuleValue };

/**
 * One action as the editor holds it. Each type has its own keys
 * (`ACTION_KEYS`) and any may be unset mid-edit; `value` is undefined until
 * chosen and null for a deliberate clear.
 */
export type RuleAction = {
  type: string;
  target?: string;
  field?: string;
  value?: RuleValue;
  mode?: string;
  people?: string[];
  title?: string;
  due_in_days?: number | null;
  priority?: string;
  assign_to?: string;
  person?: string | null;
  to?: string[];
  message?: string;
  endpoint?: string;
};

export type RuleDraft = {
  name: string;
  object_key: string;
  match: string;
  trigger: RuleTrigger;
  conditions: RuleCondition[];
  actions: RuleAction[];
};

/**
 * A rule as it arrives: a saved one, whose JSON parts the API leaves untyped,
 * or the editor's own draft.
 */
type RuleLike = {
  name?: unknown;
  object_key?: unknown;
  match?: unknown;
  trigger?: unknown;
  conditions?: unknown;
  actions?: unknown;
};

/** What the editor reads off its page's `form`. */
export type EditorForm =
  | {
      save?: { general?: string | null; rows?: Record<string, string>; plan?: boolean };
      saved?: boolean;
      switchedOff?: boolean;
      switchOff?: { general?: string };
      remove?: { general?: string };
      tried?: { recordName: string; steps: Schemas['AutomationStep'][] };
      tryError?: string;
    }
  | null
  | undefined;

export function objectOf(
  catalogue: Catalogue | null | undefined,
  key: string
): CatalogueObject | null {
  return (catalogue?.objects ?? []).find((o) => o.key === key) ?? null;
}

export function fieldOf(
  object: { fields: Field[] } | null | undefined,
  key: string | null | undefined
): Field | null {
  return (object?.fields ?? []).find((f) => f.key === key) ?? null;
}

export function triggerFields(object: { fields: Field[] } | null | undefined) {
  return (object?.fields ?? []).filter((f) => f.type !== 'people');
}

export function operatorsFor(
  catalogue: Catalogue | null | undefined,
  field: Field | null,
  event: string
): string[] {
  if (!field) return [];
  const base = catalogue?.operators?.[field.type] ?? [];
  if (event === 'updated' && field.type !== 'people') {
    return [...base, ...(catalogue?.update_only_operators ?? [])];
  }
  return [...base];
}

const OPERATOR_LABELS: Record<string, string> = {
  eq: 'is',
  neq: 'is not',
  contains: 'contains',
  not_contains: 'does not contain',
  gt: 'is more than',
  lt: 'is less than',
  in: 'is any of',
  not_in: 'is none of',
  true: 'is true',
  false: 'is false',
  includes: 'includes',
  excludes: 'does not include',
  empty: 'is empty',
  not_empty: 'is not empty',
  was: 'was',
  was_not: 'was not'
};

export function operatorLabel(op: string, fieldType?: string) {
  if (fieldType === 'date' && op === 'gt') return 'is after';
  if (fieldType === 'date' && op === 'lt') return 'is before';
  if (fieldType === 'people' && op === 'eq') return 'is exactly';
  return OPERATOR_LABELS[op] ?? op;
}

/**
 * `none`, `choices`, `people`, `person`, `boolean`, or the field's own type
 * (`text`, `number`, `date`, `choice`, ...).
 */
export function valueKind(field: { type: string }, op: string): string {
  if (['empty', 'not_empty', 'true', 'false'].includes(op)) return 'none';
  if (op === 'in' || op === 'not_in') return 'choices';
  if (field.type === 'people') return op === 'eq' ? 'people' : 'person';
  if ((op === 'was' || op === 'was_not') && field.type === 'boolean') return 'boolean';
  return field.type;
}

export function blankCondition(): RuleCondition {
  return { field: '', op: '', value: null };
}

export function blankAction(type: string): RuleAction {
  switch (type) {
    case 'create_task':
      return {
        type,
        title: '',
        due_in_days: 2,
        priority: 'Medium',
        assign_to: 'record',
        person: null
      };
    case 'notify':
      return { type, to: [], people: [], message: '' };
    case 'set_field':
      return { type, target: 'record', field: '', value: null };
    case 'assign':
      return { type, mode: 'replace', people: [] };
    case 'webhook':
      return { type, endpoint: '' };
    default:
      return { type };
  }
}

export function actionTypes(
  catalogue: Catalogue | null | undefined,
  object: CatalogueObject | null | undefined
): string[] {
  const assignees = fieldOf(object, 'assigned_to');
  const canAssign = assignees?.type === 'people' && assignees.settable;
  const canHook =
    !String(object?.key ?? '').startsWith('obj:') && (catalogue?.endpoints ?? []).length > 0;
  return (catalogue?.actions ?? []).filter(
    (a) => (a !== 'assign' || canAssign) && (a !== 'webhook' || canHook)
  );
}

/** Where `set_field` can write: the record, its parent, then each link. */
export function targetsFor(
  catalogue: Catalogue | null | undefined,
  object: CatalogueObject | null | undefined
): { value: string; label: string; object: TargetObject }[] {
  if (!object) return [];
  const out: { value: string; label: string; object: TargetObject }[] = [
    { value: 'record', label: `This ${object.label.toLowerCase()}`, object }
  ];
  if (object.parent) {
    out.push({
      value: 'parent',
      label: `Its ${object.parent.label.toLowerCase()}`,
      object: objectOf(catalogue, object.parent.key) ?? {
        key: object.parent.key,
        label: object.parent.label,
        fields: [],
        parent: null,
        links: []
      }
    });
  }
  for (const link of object.links ?? []) {
    out.push({
      value: link.id,
      label: link.label,
      object: objectOf(catalogue, link.object_key) ?? {
        key: link.object_key,
        label: link.label,
        fields: [],
        parent: null,
        links: []
      }
    });
  }
  return out;
}

export function recipientsFor(
  object: CatalogueObject | null | undefined
): { value: string; label: string }[] {
  const out = [
    { value: 'record_assignees', label: 'Its assignees' },
    { value: 'record_creator', label: 'Who created it' }
  ];
  const parent = parentAssignees(object);
  if (parent) out.push({ value: 'parent_assignees', label: parent });
  out.push({ value: 'admins', label: 'All admins' });
  for (const link of object?.links ?? []) {
    out.push({ value: `linked:${link.id}`, label: `Assignees of ${link.label}` });
  }
  return out;
}

/** Whether the object has a parent a task or notification can reach. */
export function offersParent(
  object: { key: string; parent: Schemas['AutomationCatalogueParent'] | null } | null | undefined
) {
  if (object?.key === 'task') return true;
  return (object?.key === 'deal' || object?.key === 'ticket') && Boolean(object.parent);
}

/** How the parent's assignees read in a list, or null where there is no parent. */
export function parentAssignees(
  object: { key: string; parent: Schemas['AutomationCatalogueParent'] | null } | null | undefined
): string | null {
  if (!object || !offersParent(object)) return null;
  if (object.key === 'task') return "Its parent's assignees";
  return object.parent ? `The ${object.parent.label.toLowerCase()}'s assignees` : null;
}

/** Who a created task can be for. */
export function taskAudience(
  object: CatalogueObject | null | undefined
): { value: string; label: string }[] {
  const out = [{ value: 'record', label: 'Its assignees' }];
  const parent = parentAssignees(object);
  if (parent) out.push({ value: 'parent', label: parent });
  out.push(
    { value: 'owner', label: "The rule's owner" },
    { value: 'person', label: 'A chosen person' }
  );
  return out;
}

const ACTION_LABELS: Record<string, string> = {
  set_field: 'Set a field',
  assign: 'Assign',
  create_task: 'Create a task',
  notify: 'Notify',
  webhook: 'Send to an endpoint'
};

export function actionLabel(type: string) {
  return ACTION_LABELS[type] ?? type;
}

/** How a recipient or task audience the object no longer offers reads. */
export function recipientLabel(value: string) {
  if (value.startsWith('linked:')) return 'Assignees of a removed link';
  const usual: Record<string, string> = {
    record_assignees: 'Its assignees',
    record_creator: 'Who created it',
    parent_assignees: "Its parent's assignees (no longer available)",
    parent: "Its parent's assignees (no longer available)",
    admins: 'All admins',
    record: 'Its assignees',
    owner: "The rule's owner",
    person: 'A chosen person'
  };
  return usual[value] ?? `${value} (no longer available)`;
}

/** The action types to offer, plus the stored one the catalogue lost. */
export function actionOptions(
  catalogue: Catalogue | null | undefined,
  object: CatalogueObject | null | undefined,
  stored: string
) {
  const offered = actionTypes(catalogue, object).map((t) => ({ value: t, label: actionLabel(t) }));
  return withStored(offered, stored, {
    label: (type) => `${actionLabel(type)} (no longer available)`
  });
}

/**
 * Ticking "Clear it instead" sets null; unticking brings back what the action
 * held before, or leaves the value unchosen.
 */
export function applyClear(
  action: { value?: RuleValue },
  on: boolean,
  previous: RuleValue | undefined
) {
  action.value = on ? null : (previous ?? undefined);
}

/** Null is a deliberate clear. */
export function isClearing(action: { value?: RuleValue }) {
  return action.value === null;
}

/**
 * A value from the input. Null from a select or number input means nothing is
 * chosen, never a clear.
 */
export function setActionValue(action: { value?: RuleValue }, value: RuleValue | undefined) {
  action.value = value === null ? undefined : value;
}

/** What the value input shows: a placeholder while nothing is chosen. */
export function shownValue(action: { value?: RuleValue }): RuleValue {
  return action.value === undefined ? null : action.value;
}

/** Changing assign's mode empties its people, which differ in count. */
export function applyMode(action: RuleAction, mode: string) {
  action.mode = mode;
  action.people = [];
}

/** A `set_field` row pointed at another target starts over, in place. */
export function applyTarget(action: RuleAction, target: string) {
  action.target = target;
  action.field = '';
  action.value = undefined;
}

/** A chosen field has no value yet; an absent value is refused, a null one clears. */
export function applyField(action: RuleAction, field: string) {
  action.field = field;
  action.value = undefined;
}

/** Who a task is for; only a chosen person keeps a person. */
export function applyAssignTo(action: RuleAction, who: string) {
  action.assign_to = who;
  if (who !== 'person') action.person = null;
}

/**
 * Options plus any stored value they no longer carry, so editing a rule never
 * silently drops what it holds.
 *
 * Only text values can be options; any other kind of stored value is the
 * input's own, which draws no options.
 *
 * @param stored One value, a list of them, or empty.
 * @param opts `person`: stored values are member ids. `label`: how a lost value reads.
 */
export function withStored(
  options: Option[],
  stored: unknown,
  {
    person = false,
    label = undefined
  }: { person?: boolean; label?: (value: string) => string | undefined } = {}
): Option[] {
  const out = [...options];
  const seen = new Set(options.map((o) => o.value));
  const values: unknown[] = Array.isArray(stored) ? stored : [stored];
  for (const value of values) {
    if (typeof value !== 'string' || value === '' || seen.has(value)) continue;
    seen.add(value);
    out.push({
      value,
      label:
        label?.(value) ?? (person ? 'Someone no longer active' : `${value} (no longer available)`),
      group: '',
      settable: false,
      gone: true
    });
  }
  return out;
}

/**
 * The person a replace assign shows as chosen. A stored rule can hold several
 * though the API takes exactly one, so none is preselected then and the admin
 * chooses who stays.
 */
export function replacePerson(action: { people?: string[] }): { id: string; several: boolean } {
  const people = Array.isArray(action?.people) ? action.people : [];
  return { id: people.length === 1 ? people[0] : '', several: people.length > 1 };
}

export function triggerSentence(
  rule: { object_key?: string; trigger?: unknown } | null | undefined,
  catalogue: Catalogue | null | undefined
) {
  const trigger = asObject(rule?.trigger) ?? {};
  if (trigger.event === 'created') return 'Created';
  if (!trigger.field) return 'Updated';
  const field =
    typeof trigger.field === 'string'
      ? fieldOf(objectOf(catalogue, rule?.object_key ?? ''), trigger.field)
      : null;
  if (!field) return 'A field that is no longer available changes';
  const base = `${field.label} changes`;
  const to = trigger.to;
  if (to === undefined || to === null) return base;
  if (field.type === 'boolean') return `${base} to ${to === true || to === 'true' ? 'Yes' : 'No'}`;
  if (field.type === 'choice') {
    const option = field.choices.find((c) => c.value === String(to));
    return `${base} to ${option ? option.label : String(to)}`;
  }
  return `${base} to ${String(to)}`;
}

export function runsLabel(row: { runs_7d?: number; failures_7d?: number }) {
  const runs = row?.runs_7d ?? 0;
  if (!runs) return 'No runs';
  const text = `${runs} ${runs === 1 ? 'run' : 'runs'}`;
  return row.failures_7d ? `${text}, ${row.failures_7d} failed` : text;
}

/** Names for a rule's object when the catalogue no longer lists it. */
export const OBJECT_LABELS = {
  lead: 'Lead',
  contact: 'Contact',
  account: 'Account',
  deal: 'Deal',
  ticket: 'Ticket',
  task: 'Task'
} as Record<string, string>;

/**
 * A rule the server paused because its object's module is switched off.
 * It resumes by itself when the module is back on.
 */
export function pausedByModule(
  row: { status?: string; object_key?: string } | null | undefined,
  modules: ModuleRow[] | null | undefined
): boolean {
  const key = OBJECT_MODULES[row?.object_key ?? ''];
  return row?.status === 'paused' && Boolean(key) && !isOn(modules, key);
}

/** The note for a rule paused by its module. */
export function modulePausedNote(row: { name?: string; status_text?: string }): string {
  return `"${row.name}": ${row.status_text}. It runs again once that module is switched back on.`;
}

export const STATUS: Record<string, { label: string; tone: Tone }> = {
  on: { label: 'On', tone: 'moss' },
  off: { label: 'Off', tone: 'slate' },
  paused: { label: 'Paused', tone: 'clay' },
  over_limit: { label: 'Not running', tone: 'clay' },
  needs_attention: { label: 'Needs attention', tone: 'rust' }
};

/**
 * The line under a list row's pill, or null. A paused rule's sentence is shown
 * once, in its paused note above the list.
 */
export function statusNote(
  rule: { status?: string; status_text?: string } | null | undefined
): string | null {
  if (!rule?.status_text || rule.status === 'paused') return null;
  const label = STATUS[rule.status ?? '']?.label;
  return rule.status_text === (label ?? rule.status) ? null : rule.status_text;
}

/** What a run's card head says beside its time and record. */
export function runNotes(
  run: { reason?: unknown; triggered_by?: { rule_name?: unknown } | null } | null | undefined
): { reason: string | null; by: string | null } {
  const reason = typeof run?.reason === 'string' && run.reason ? run.reason : null;
  const rule = run?.triggered_by?.rule_name;
  return { reason, by: typeof rule === 'string' && rule ? `Set off by "${rule}"` : null };
}

export { recordHref as recordRoute } from '#lib/v2/custom-objects.js';

const ACTION_KEYS: Record<string, string[]> = {
  set_field: ['target', 'field', 'value'],
  assign: ['mode', 'people'],
  create_task: ['title', 'due_in_days', 'priority', 'assign_to', 'person'],
  notify: ['to', 'people', 'message'],
  webhook: ['endpoint']
};

function asObject(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function isScalar(value: unknown): value is string | number | boolean {
  return typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean';
}

function isRuleValue(value: unknown): value is RuleValue {
  return value === null || isScalar(value) || (Array.isArray(value) && value.every(isScalar));
}

function isTextList(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === 'string');
}

const textOr = (value: unknown, fallback: string) => (typeof value === 'string' ? value : fallback);

/**
 * A stored trigger, or the created trigger a new rule starts with. Anything
 * the validator would not have saved is dropped rather than carried.
 */
function readTrigger(raw: unknown): RuleTrigger {
  if (raw === null || raw === undefined) return { event: 'created' };
  const trigger = asObject(raw) ?? {};
  const t: RuleTrigger = { event: textOr(trigger.event, '') };
  if (Object.hasOwn(trigger, 'field')) {
    const field = trigger.field;
    if (typeof field === 'string' || field === null) t.field = field;
  }
  if (Object.hasOwn(trigger, 'to') && isRuleValue(trigger.to)) t.to = trigger.to;
  return t;
}

function readCondition(raw: unknown): RuleCondition {
  const c = asObject(raw) ?? {};
  return {
    field: textOr(c.field, ''),
    op: textOr(c.op, ''),
    value: isRuleValue(c.value) ? c.value : null
  };
}

/** An action with only its type's keys, each of the kind the validator takes. */
function readAction(raw: unknown): RuleAction {
  const a = asObject(raw) ?? {};
  const type = textOr(a.type, '');
  const out: RuleAction = { type };
  for (const key of Object.hasOwn(ACTION_KEYS, type) ? ACTION_KEYS[type] : []) {
    if (!Object.hasOwn(a, key)) continue;
    const v = a[key];
    switch (key) {
      case 'value':
        if (isRuleValue(v)) out.value = v;
        break;
      case 'people':
      case 'to':
        if (isTextList(v)) out[key] = v;
        break;
      case 'due_in_days':
        if (v === null || typeof v === 'number') out.due_in_days = v;
        break;
      case 'person':
        if (v === null || typeof v === 'string') out.person = v;
        break;
      case 'target':
      case 'field':
      case 'mode':
      case 'title':
      case 'priority':
      case 'assign_to':
      case 'message':
      case 'endpoint':
        if (typeof v === 'string') out[key] = v;
        break;
    }
  }
  return out;
}

/**
 * The rule's body keys in a fixed order, copied, so two drafts compare by what
 * would be saved.
 */
function normalise(rule: RuleLike | null | undefined, objectKey: string): RuleDraft {
  const draft = {
    name: textOr(rule?.name, ''),
    object_key: textOr(rule?.object_key, objectKey),
    match: textOr(rule?.match, 'all'),
    trigger: readTrigger(rule?.trigger),
    conditions: Array.isArray(rule?.conditions) ? rule.conditions.map(readCondition) : [],
    actions: Array.isArray(rule?.actions) ? rule.actions.map(readAction) : []
  };
  return JSON.parse(JSON.stringify(draft)) as RuleDraft;
}

/** @param objectKey Used for a new rule. */
export function editorState(rule: RuleLike | null, objectKey: string) {
  return normalise(rule, objectKey);
}

export function isDirty(draft: RuleLike, saved: RuleLike) {
  return JSON.stringify(normalise(draft, '')) !== JSON.stringify(normalise(saved, ''));
}

/**
 * Why Try is unavailable: the hint to show, `''` when blocked with nothing to
 * say (sending, or no record chosen), or null when it may run.
 */
export function tryBlocked({
  dirty,
  busy,
  chosen
}: {
  dirty: boolean;
  busy: boolean;
  chosen: unknown[];
}): string | null {
  if (dirty) return 'Save first: Try uses the saved rule.';
  return busy || chosen.length === 0 ? '' : null;
}

/** @param direction 1 up, 1 down */
export function moveItem<T>(list: T[], index: number, direction: number): T[] {
  const next = [...list];
  const to = index + direction;
  if (index < 0 || index >= next.length || to < 0 || to >= next.length) return next;
  [next[index], next[to]] = [next[to], next[index]];
  return next;
}

/**
 * A condition's value once its operator changes. It survives only while the
 * new operator reads the same kind of value, so a stale one is never sent.
 */
export function keptValue(
  field: Field | null,
  fromOp: string,
  toOp: string,
  value: RuleValue | undefined
): RuleValue {
  if (!field) return null;
  const kind = valueKind(field, toOp);
  return kind === 'none' || kind !== valueKind(field, fromOp) ? null : (value ?? null);
}

/**
 * The draft moved to another object: conditions go, and so does any action the
 * object cannot take; a task for a missing parent falls back to the record.
 */
export function switchObject(
  draft: RuleDraft,
  catalogue: Catalogue | null | undefined,
  key: string
): RuleDraft {
  const copy = JSON.parse(JSON.stringify(draft)) as RuleDraft;
  const next = objectOf(catalogue, key);
  const offered = new Set(recipientsFor(next).map((r) => r.value));
  const offeredTypes = actionTypes(catalogue, next);
  const parent = offersParent(next);
  return {
    ...copy,
    object_key: key,
    trigger: { event: copy.trigger?.event ?? 'created' },
    conditions: [],
    actions: (copy.actions ?? [])
      .filter((a) => offeredTypes.includes(a.type))
      .map((a) => {
        if (a.type === 'create_task' && a.assign_to === 'parent' && !parent) {
          return { ...a, assign_to: 'record' };
        }
        if (a.type === 'set_field') return blankAction('set_field');
        if (a.type === 'notify') {
          return { ...a, to: (a.to ?? []).filter((v) => offered.has(v)) };
        }
        return a;
      })
  };
}

/** The note under a "changes to" value, or null until there is one. */
export function changeHint(field: Field | null, to: RuleValue | undefined) {
  if (!field || to === undefined || to === null || to === '') return null;
  let value = String(to);
  if (field.type === 'boolean') value = to === true || to === 'true' ? 'Yes' : 'No';
  if (field.type === 'choice') {
    value = field.choices.find((c) => c.value === value)?.label ?? value;
  }
  return `Runs once, when the ${field.label.toLowerCase()} moves into ${value}; later edits do not run it again.`;
}

/**
 * A save's errors split between the rows the page shows and one general line
 * for the rest, so no refusal goes unseen.
 */
export function placeErrors(
  save: { general?: string | null; rows?: Record<string, string> } | null | undefined,
  shown: (key: string) => boolean
): { general: string | null; rows: Record<string, string> } {
  const rows: Record<string, string> = {};
  const rest = save?.general ? [save.general] : [];
  for (const [key, message] of Object.entries(save?.rows ?? {})) {
    const row = /^(conditions|actions)\.(\d+)$/.exec(key);
    if (shown(key)) rows[key] = message;
    else if (row) {
      rest.push(
        `${row[1] === 'conditions' ? 'Condition' : 'Action'} ${Number(row[2]) + 1}: ${message}`
      );
    } else rest.push(message);
  }
  return { general: rest.length ? rest.join(' ') : null, rows };
}

/** Keys the editor shows under their own section or field. */
const SECTION_KEYS = ['name', 'match', 'trigger', 'conditions', 'actions'];

/** Rows are compared by identity and by their JSON, so any row object will do. */
type SentRows = {
  conditions: object[];
  actions: object[];
  copies: { conditions: string[]; actions: string[] };
};

/**
 * The rows a save sends: the row objects themselves, and a copy of each as it
 * was, so `editorErrors` can tell a row edited since.
 */
export function sentRows(draft: { conditions?: object[]; actions?: object[] }): SentRows {
  const conditions = [...(draft?.conditions ?? [])];
  const actions = [...(draft?.actions ?? [])];
  const copy = (row: object) => JSON.stringify(row);
  return {
    conditions,
    actions,
    copies: { conditions: conditions.map(copy), actions: actions.map(copy) }
  };
}

/**
 * A save's errors as the editor shows them. A row's message goes to the row
 * object it was sent as, so it stays with that row when another is removed,
 * and leaves once that row is edited; anything with no place on the page
 * joins the general line.
 * @param sent From `sentRows` when the save was sent.
 * @param current The rows on the page now.
 */
export function editorErrors(
  save: { general?: string | null; rows?: Record<string, string> } | null | undefined,
  sent: SentRows,
  current: { conditions: object[]; actions?: object[] }
): {
  general: string | null;
  rows: Record<string, string>;
  conditions: (string | null)[];
  actions: (string | null)[];
} {
  const asSent = { conditions: sent?.conditions ?? [], actions: sent?.actions ?? [] };
  const placed = placeErrors(save, (key) => {
    if (SECTION_KEYS.includes(key)) return true;
    const at = /^(conditions|actions)\.(\d+)$/.exec(key);
    return Boolean(at) && Number(at?.[2]) < asSent[at?.[1] as 'conditions' | 'actions'].length;
  });
  const onRows = (kind: 'conditions' | 'actions') =>
    (current?.[kind] ?? []).map((row) => {
      const at = asSent[kind].indexOf(row);
      if (at === -1 || sent?.copies?.[kind]?.[at] !== JSON.stringify(row)) return null;
      return placed.rows[`${kind}.${at}`] ?? null;
    });
  // "Add at least one action." and its like are about the list as sent.
  const now = current?.actions ?? [];
  const same = now.length === asSent.actions.length && now.every((a, i) => a === asSent.actions[i]);
  const { actions: listError, ...rows } = placed.rows;
  return {
    general: placed.general,
    rows: same && listError ? { ...rows, actions: listError } : rows,
    conditions: onRows('conditions'),
    actions: onRows('actions')
  };
}

/**
 * A saved rule's status: its list row's, or else what the rule itself says.
 * Null for a rule not saved yet.
 */
export function ruleStatus(
  rule: { is_active?: boolean; paused_reason?: string } | null | undefined,
  row: { status?: string } | null | undefined
): string | null {
  if (!rule) return null;
  if (row?.status) return row.status;
  return rule.is_active ? 'on' : rule.paused_reason ? 'paused' : 'off';
}

/**
 * The second save button for a status, or null when the rule is already on.
 * @param status Null for a rule not saved yet.
 */
export function switchLabel(status: string | null | undefined) {
  if (status === 'paused') return 'Save and take over';
  if (status === 'off' || status === null || status === undefined) return 'Save and switch on';
  return null;
}

/**
 * Whether the Settings hub offers the Automation row: admins only, and not
 * where the API answered 404 (`automationSummary` returns false there).
 */
export function showAutomationSetting(
  summary: { active: number; failing: number; attention: boolean } | null | false,
  isAdmin: boolean
): boolean {
  return isAdmin && summary !== false;
}

/** The settings hub row's value and warning from `automationSummary`. */
export function hubValue(
  summary: { active: number; failing: number; attention: boolean } | null | false | undefined
): { value: string | null; warn: boolean } {
  if (!summary) return { value: null, warn: false };
  const rules = summary.active
    ? `${summary.active} active ${summary.active === 1 ? 'rule' : 'rules'}`
    : 'No active rules';
  return {
    value: summary.failing > 0 ? `${rules}, ${summary.failing} failing` : rules,
    warn: Boolean(summary.attention)
  };
}

const str = (v: unknown): v is string => typeof v === 'string';

/**
 * The sentence an automation, project budget, retainer invoice or estimate notification shows,
 * composed from `data`. Null for any other verb or data of the wrong type, so
 * the row keeps its usual copy; an estimate's verb has a fallback sentence
 * instead (see `estimateNotificationText`).
 */
export function notificationText(
  n: { verb?: string; data?: unknown } | null | undefined,
  timeZone: string
): { text: string; source: string | null } | null {
  const estimate = estimateNotificationText(n?.verb, n?.data);
  if (estimate) return { text: estimate, source: null };
  const d = asObject(n?.data);
  if (!d || !n) return null;
  switch (n.verb) {
    case 'automation.message':
      if (!str(d.message) || !str(d.rule)) return null;
      return { text: d.message, source: `From the rule "${d.rule}"` };
    case 'automation.failed':
      if (!str(d.rule) || !str(d.reason)) return null;
      return { text: `The rule "${d.rule}" failed: ${d.reason}`, source: null };
    case 'automation.paused':
      if (!str(d.reason) || !Array.isArray(d.rules) || !d.rules.every(str)) return null;
      return { text: `${d.reason} Paused: ${d.rules.join(', ')}.`, source: null };
    case 'automation.limit': {
      if (!str(d.window_start)) return null;
      const from = runTime(d.window_start, timeZone).replace(/^(Today|Yesterday) /, (w) =>
        w.toLowerCase()
      );
      return {
        text: `Automation reached its limit of 1,000 runs in the hour from ${from}. The rest of that hour's runs were skipped.`,
        source: null
      };
    }
    case 'project.budget': {
      const text = budgetNotificationText(d);
      return text ? { text, source: null } : null;
    }
    case 'project.retainer_invoice': {
      const text = retainerInvoiceNotificationText(d);
      return text ? { text, source: null } : null;
    }
    default:
      return null;
  }
}

/**
 * Who a notification row credits. The API's actor carries `user_details.email`
 * and no `name`.
 */
export function actorName(
  n:
    | { actor?: { id?: string; name?: string; user_details?: { email?: string } | null } | null }
    | null
    | undefined
): string {
  return n?.actor?.name || n?.actor?.user_details?.email || 'Someone';
}

export const AUTOMATION_FALLBACK = 'An automation rule sent a notification.';
