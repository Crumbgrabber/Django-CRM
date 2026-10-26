/**
 * Server-side calls to the modules API (`/api/org/modules/`), the guard of
 * module pages, and the page an API `module_off` refusal becomes.
 *
 * Any member reads; only an admin writes, and the server decides. A failed
 * read answers null, which every caller treats as "all modules on".
 */

import { error, type Cookies } from '@sveltejs/kit';
import { apiRequest } from '#lib/api-helpers.js';
import { apiErrorBody, apiStatus } from '#lib/api-errors.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { refusalFor, requirementFor, type ModuleRow } from '#lib/v2/modules.js';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

type ModulesAnswer = { modules: ModuleRow[]; canEdit: boolean };

type ModulesEvent = { cookies: Cookies; locals?: object };

function shape(data: { modules?: ModuleRow[]; can_edit?: boolean } | null): ModulesAnswer | null {
  if (!data || !Array.isArray(data.modules)) return null;
  return { modules: data.modules, canEdit: data.can_edit === true };
}

const reads: WeakMap<object, Promise<ModulesAnswer | null>> = new WeakMap();

/**
 * The list, read once per request: every load of a request (the shell, a
 * folder guard, the page) gets the same read through `event.locals`.
 */
export function getModules(event: ModulesEvent): Promise<ModulesAnswer | null> {
  const locals = event?.locals;
  if (!locals || typeof locals !== 'object') return readModules(event);
  let read = reads.get(locals);
  if (!read) {
    read = readModules(event);
    reads.set(locals, read);
  }
  return read;
}

async function readModules(event: ModulesEvent): Promise<ModulesAnswer | null> {
  try {
    const data: Schemas['OrgModulesResponse'] = await apiRequest(
      '/org/modules/',
      { quietErrors: true, expectedStatuses: [404] },
      event
    );
    return shape(data);
  } catch {
    return null;
  }
}

export async function putModules(
  event: ModulesEvent,
  { off, order }: { off: string[]; order: string[] }
): Promise<ModulesAnswer | null> {
  try {
    const data: Schemas['OrgModulesResponse'] = await apiRequest(
      '/org/modules/',
      { method: 'PUT', body: { off, order } },
      event
    );
    return shape(data);
  } finally {
    // A form post without JavaScript runs the loads in the same request.
    if (event?.locals) reads.delete(event.locals);
  }
}

/** The body that flips one module, keeping the order as served. */
export function switchBody(
  rows: ModuleRow[],
  key: string,
  on: boolean
): { off: string[]; order: string[] } | null {
  if (!rows.some((r) => r.key === key)) return null;
  const off = rows.filter((r) => !r.enabled && r.key !== key).map((r) => r.key);
  if (!on) off.push(key);
  return {
    off: rows.map((r) => r.key).filter((k) => off.includes(k)),
    order: rows.map((r) => r.key)
  };
}

/**
 * The body that swaps a module with its neighbour in the same group.
 *
 * @param direction `up` or `down`
 */
export function moveBody(
  rows: ModuleRow[],
  key: string,
  direction: string
): { off: string[]; order: string[] } | null {
  if (direction !== 'up' && direction !== 'down') return null;
  const row = rows.find((r) => r.key === key);
  if (!row) return null;
  const peers = rows.filter((r) => r.group === row.group);
  const at = peers.indexOf(row);
  const other = peers[direction === 'up' ? at - 1 : at + 1];
  if (!other) return null;
  const order = rows.map((r) => r.key);
  const a = order.indexOf(row.key);
  const b = order.indexOf(other.key);
  [order[a], order[b]] = [order[b], order[a]];
  return { off: rows.filter((r) => !r.enabled).map((r) => r.key), order };
}

/** @param err the error thrown by `putModules` */
export function moduleErrors(err: unknown): string[] {
  const body = apiErrorBody(err);
  const status = apiStatus(err);
  if (status === 400 && body) {
    const out: string[] = [];
    for (const field of ['off', 'order']) {
      const list = body[field];
      if (Array.isArray(list)) out.push(...list.filter((m) => typeof m === 'string'));
      else if (typeof list === 'string') out.push(list);
    }
    if (out.length) return out;
  }
  if (status === 403) {
    const text = body?.errors ?? body?.detail;
    if (typeof text === 'string' && text.trim()) return [text];
  }
  return [readableError(err, 'Could not save the modules.')];
}

/**
 * The `load` of each folder holding a module page: a page of a switched-off
 * module becomes the module page, rendered by `(app)/+error.svelte`.
 *
 * It asks for the list itself, and only on a module route: `parent()` would
 * rerun the whole shell load on every client-side navigation.
 */
export async function moduleGuard(event: { route: { id: string | null }; cookies: Cookies }) {
  if (!requirementFor(event.route.id)) return {};
  const answer = await getModules(event);
  const refusal = refusalFor(event.route.id, answer?.modules ?? null);
  if (refusal) {
    error(404, `${refusal.label} is switched off for this organization.`, {
      code: 'module_off',
      module: refusal.key,
      label: refusal.label
    });
  }
  return {};
}

/**
 * The page error for an API `module_off` refusal, or undefined for any other
 * error. The 409 delete refusal is a form's message, not a page.
 *
 * @param err an error thrown by `apiRequest`
 */
export function moduleOffError(err: unknown): App.Error | undefined {
  const body = apiErrorBody(err);
  if (apiStatus(err) !== 404 || body?.code !== 'module_off') return undefined;
  const module = typeof body.module === 'string' ? body.module : undefined;
  return { status: 404, message: body.detail ?? '', code: 'module_off', module };
}

/** Throws the module page when `err` is a `module_off` refusal; returns otherwise. */
export function rethrowModuleOff(err: unknown) {
  const off = moduleOffError(err);
  if (off) error(404, off.message, { code: off.code, module: off.module });
}

/**
 * The `detail` of an upstream `module_off` 404, or null. Reads the body, so
 * call it only on a response that is not passed on.
 */
export async function moduleOffDetail(response: Response): Promise<string | null> {
  if (response.status !== 404) return null;
  try {
    const body = (await response.json()) as { code?: unknown; detail?: unknown } | null;
    return body?.code === 'module_off' && typeof body.detail === 'string' ? body.detail : null;
  } catch {
    return null;
  }
}
