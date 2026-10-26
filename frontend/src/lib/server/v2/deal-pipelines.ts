/**
 * Deal pipelines: the wiring behind `/settings/deal-pipelines`.
 *
 * Server-only (the access token is read from an httpOnly cookie in here).
 * Reads `GET /opportunities/pipelines/`, which lists every pipeline with its
 * stages in board order, so one request draws the whole page.
 *
 * READ IS OPEN, WRITE IS ADMIN-ONLY
 * Every member can read pipelines (the board and the deal forms need them).
 * Every write below is refused with a 403 by
 * `opportunity/views/pipeline_views.py` unless the caller is an org admin or a
 * superuser. `can_edit` mirrors that so the page hides controls a member could
 * only be turned away from; it is decoded from the JWT and is a display hint,
 * never the check.
 */
import { apiRequest, type FormBody } from '#lib/api-helpers.js';
import { listPipelines } from './deals.js';
import { viewerIsAdmin } from './organization.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

/**
 * Every pipeline, and the one whose stages are on screen. An absent or
 * unknown `pipelineId` falls back to the default pipeline, so a stale link
 * shows a pipeline rather than an error.
 */
export async function getDealPipelines(
  { cookies }: { cookies: Cookies },
  pipelineId: string | null = null
) {
  const pipelines = await listPipelines(cookies);
  const pipeline =
    pipelines.find((p) => p.id === pipelineId) ??
    pipelines.find((p) => p.is_default) ??
    pipelines[0] ??
    null;
  return { pipelines, pipeline, can_edit: viewerIsAdmin(cookies) };
}

/**
 * The API seeds a new pipeline with the six default stages.
 *
 * @returns the created pipeline
 */
export async function createPipeline(
  { cookies }: { cookies: Cookies },
  { name }: { name: string }
): Promise<Schemas['DealPipeline']> {
  return await apiRequest(
    '/opportunities/pipelines/',
    { method: 'POST', body: { name } },
    { cookies }
  );
}

export async function renamePipeline(
  { cookies }: { cookies: Cookies },
  id: string,
  { name }: { name: string }
): Promise<Schemas['DealPipeline']> {
  return await apiRequest(
    `/opportunities/pipelines/${id}/`,
    { method: 'PATCH', body: { name } },
    { cookies }
  );
}

/** Refused with a 400 for the default pipeline, and while any deal is in it. */
export async function deletePipeline({ cookies }: { cookies: Cookies }, id: string) {
  return await apiRequest(`/opportunities/pipelines/${id}/`, { method: 'DELETE' }, { cookies });
}

/**
 * The stage fields this page edits, as the serializer wants them. Blank
 * rotting days go as `null`: the stage never rots. The server clears both for
 * a won or lost stage, which does not age.
 */
function stageBody({
  label,
  kind,
  expectedDays,
  warningDays
}: {
  label: string;
  kind: string;
  expectedDays: string;
  warningDays: string;
}): FormBody<Schemas['DealStageRequest']> {
  return {
    label,
    kind,
    expected_days: expectedDays === '' ? null : Number(expectedDays),
    warning_days: warningDays === '' ? null : Number(warningDays)
  };
}

/**
 * Appended as the pipeline's last stage; its code is derived server-side.
 *
 * @returns the pipeline, with the new stage
 */
export async function createStage(
  { cookies }: { cookies: Cookies },
  pipelineId: string,
  values: { label: string; kind: string; expectedDays: string; warningDays: string }
): Promise<Schemas['DealPipeline']> {
  return await apiRequest(
    `/opportunities/pipelines/${pipelineId}/stages/`,
    { method: 'POST', body: stageBody(values) },
    { cookies }
  );
}

/**
 * Refused with a 400 when the kind changes while deals are in the stage, or
 * when it is the pipeline's last stage of its kind.
 *
 * @returns the stage's pipeline
 */
export async function updateStage(
  { cookies }: { cookies: Cookies },
  id: string,
  values: { label: string; kind: string; expectedDays: string; warningDays: string }
): Promise<Schemas['DealPipeline']> {
  return await apiRequest(
    `/opportunities/stages/${id}/`,
    { method: 'PATCH', body: stageBody(values) },
    { cookies }
  );
}

/**
 * Refused with a 400 while deals are in the stage, and for the pipeline's
 * last open, won or lost stage.
 */
export async function deleteStage({ cookies }: { cookies: Cookies }, id: string) {
  return await apiRequest(`/opportunities/stages/${id}/`, { method: 'DELETE' }, { cookies });
}

/**
 * Move one stage a place up or down. The reorder endpoint takes every stage id
 * of the pipeline exactly once, so the current order is read fresh here rather
 * than taken from the form: a page left open while another admin added a
 * stage would otherwise send an incomplete list, which the endpoint refuses.
 *
 * @returns false when the stage is not in the pipeline or is already at that end
 */
export async function moveStage(
  { cookies }: { cookies: Cookies },
  pipelineId: string,
  stageId: string,
  direction: 'up' | 'down'
): Promise<boolean> {
  const detail: Schemas['DealPipeline'] = await apiRequest(
    `/opportunities/pipelines/${pipelineId}/`,
    {},
    { cookies }
  );
  const ids = (detail.stages ?? []).map((s) => String(s.id));
  const from = ids.indexOf(stageId);
  const to = direction === 'up' ? from - 1 : from + 1;
  if (from === -1 || to < 0 || to >= ids.length) return false;
  [ids[from], ids[to]] = [ids[to], ids[from]];
  await apiRequest(
    `/opportunities/pipelines/${pipelineId}/stages/reorder/`,
    { method: 'POST', body: { stage_ids: ids } },
    { cookies }
  );
  return true;
}
