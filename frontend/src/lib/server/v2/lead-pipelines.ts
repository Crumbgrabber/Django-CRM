/**
 * Lead pipelines: the wiring behind `/settings/lead-pipelines`.
 *
 * Server-only (the access token is read from an httpOnly cookie in here).
 * Reads `GET /leads/pipelines/` for the list, then `GET /leads/pipelines/<id>/`
 * for the one pipeline whose stages are on screen.
 *
 * READ IS OPEN, WRITE IS ADMIN-ONLY
 * Every member can read pipelines (the board needs them). Every write below is
 * refused with a 403 by `leads/views/kanban_views.py` unless the caller is an
 * org admin or a superuser. `can_edit` mirrors that so the page hides controls
 * a member could only be turned away from; it is decoded from the JWT and is a
 * display hint, never the check.
 */
import { apiRequest, type FormBody } from '#lib/api-helpers.js';
import { viewerIsAdmin } from './organization.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

/**
 * The page: every active pipeline, and the stages of the selected one. An
 * absent or unknown `pipelineId` falls back to the first listed, so a stale
 * link shows a pipeline rather than an error.
 */
export async function getLeadPipelines(
  { cookies }: { cookies: Cookies },
  pipelineId: string | null = null
) {
  const listed: Schemas['LeadPipelineListResponse'] = await apiRequest(
    '/leads/pipelines/',
    {},
    { cookies }
  );
  const pipelines = (listed.pipelines ?? []).map((p) => ({
    id: p.id,
    name: p.name,
    stageCount: p.stage_count ?? 0,
    leadCount: p.lead_count ?? 0,
    isDefault: Boolean(p.is_default)
  }));
  const can_edit = viewerIsAdmin(cookies);
  if (pipelines.length === 0) return { pipelines, pipeline: null, can_edit };

  const chosen = pipelines.find((p) => p.id === pipelineId) ?? pipelines[0];
  const detail: Schemas['LeadPipeline'] = await apiRequest(
    `/leads/pipelines/${chosen.id}/`,
    {},
    { cookies }
  );
  const stages = [...(detail.stages ?? [])]
    .sort((a, b) => (a.order ?? 0) - (b.order ?? 0))
    .map((s) => ({
      id: s.id,
      name: s.name,
      stageType: s.stage_type,
      mapsToStatus: s.maps_to_status || '',
      winProbability: s.win_probability ?? 0,
      leadCount: s.lead_count ?? 0
    }));

  return {
    pipelines,
    pipeline: {
      id: detail.id,
      name: detail.name,
      description: detail.description ?? '',
      leadCount: detail.lead_count ?? 0,
      stages
    },
    can_edit
  };
}

/** @returns the created pipeline, stages seeded */
export async function createPipeline(
  { cookies }: { cookies: Cookies },
  { name }: { name: string }
): Promise<Schemas['LeadPipeline']> {
  return await apiRequest(
    '/leads/pipelines/',
    {
      method: 'POST',
      body: { name, create_default_stages: true } satisfies Schemas['LeadPipelineCreateRequest']
    },
    { cookies }
  );
}

export async function renamePipeline(
  { cookies }: { cookies: Cookies },
  id: string,
  { name }: { name: string }
): Promise<Schemas['LeadPipeline']> {
  return await apiRequest(
    `/leads/pipelines/${id}/`,
    { method: 'PUT', body: { name } },
    { cookies }
  );
}

/**
 * Soft delete. Refused with a 400 naming the count while any lead the board
 * shows is still in one of its stages.
 */
export async function deletePipeline({ cookies }: { cookies: Cookies }, id: string) {
  return await apiRequest(`/leads/pipelines/${id}/`, { method: 'DELETE' }, { cookies });
}

/**
 * The four stage fields this page edits, as the serializer wants them. An
 * empty `maps_to_status` goes as `null`, which clears it.
 */
function stageBody({
  name,
  stageType,
  mapsToStatus,
  winProbability
}: {
  name: string;
  stageType: string;
  mapsToStatus: string;
  winProbability: string;
}): FormBody<Schemas['LeadStageRequest']> {
  return {
    name,
    stage_type: stageType,
    maps_to_status: mapsToStatus || null,
    win_probability: winProbability === '' ? 0 : Number(winProbability)
  };
}

/**
 * Appended as the last stage: the backend orders a stage sent without one
 * after the others.
 */
export async function createStage(
  { cookies }: { cookies: Cookies },
  pipelineId: string,
  values: { name: string; stageType: string; mapsToStatus: string; winProbability: string }
): Promise<Schemas['LeadStage']> {
  return await apiRequest(
    `/leads/pipelines/${pipelineId}/stages/`,
    { method: 'POST', body: stageBody(values) },
    { cookies }
  );
}

export async function updateStage(
  { cookies }: { cookies: Cookies },
  id: string,
  values: { name: string; stageType: string; mapsToStatus: string; winProbability: string }
): Promise<Schemas['LeadStage']> {
  return await apiRequest(
    `/leads/stages/${id}/`,
    { method: 'PUT', body: stageBody(values) },
    { cookies }
  );
}

/** Refused with a 400 naming the count while the stage still holds leads. */
export async function deleteStage({ cookies }: { cookies: Cookies }, id: string) {
  return await apiRequest(`/leads/stages/${id}/`, { method: 'DELETE' }, { cookies });
}

/**
 * Move one stage a place up or down. The reorder endpoint takes every stage id
 * of the pipeline, so the current order is read fresh here rather than taken
 * from the form: a page left open while another admin added a stage would
 * otherwise send an incomplete list, which the endpoint refuses.
 *
 * @returns false when the stage is not in the pipeline or is already at that end
 */
export async function moveStage(
  { cookies }: { cookies: Cookies },
  pipelineId: string,
  stageId: string,
  direction: 'up' | 'down'
): Promise<boolean> {
  const detail: Schemas['LeadPipeline'] = await apiRequest(
    `/leads/pipelines/${pipelineId}/`,
    {},
    { cookies }
  );
  const ids = [...(detail.stages ?? [])]
    .sort((a, b) => (a.order ?? 0) - (b.order ?? 0))
    .map((s) => String(s.id));
  const from = ids.indexOf(stageId);
  const to = direction === 'up' ? from - 1 : from + 1;
  if (from === -1 || to < 0 || to >= ids.length) return false;
  [ids[from], ids[to]] = [ids[to], ids[from]];
  await apiRequest(
    `/leads/pipelines/${pipelineId}/stages/reorder/`,
    { method: 'POST', body: { stage_ids: ids } },
    { cookies }
  );
  return true;
}
