/**
 * The lead pipeline board: leads grouped by the stages of a `LeadPipeline`.
 *
 * Server-only, for the same reason as `leads.js`: the access token is read
 * from an httpOnly cookie in here.
 *
 * Read in two calls. `GET /leads/pipelines/` lists the org's active pipelines
 * (a vertical pack creates one, which is the reason this page exists), then
 * `GET /leads/kanban/?pipeline_id=` returns that pipeline's stages with their
 * cards. The kanban endpoint applies the same visibility rule as the lead
 * list, so a member's board holds only the leads their list does.
 *
 * `unstaged` is the lane of leads in no pipeline at all. A lead is created
 * with no stage, so without this lane a pack's pipeline would stay empty: the
 * way a lead enters a pipeline is being moved from here to a stage.
 *
 * One write: `PATCH /leads/<id>/move/` with a `stage_id`, or `null` to take
 * the lead back out to "No stage". The backend checks the caller may edit the
 * lead, that the stage is in the org and in an active pipeline, and that a
 * lead already in a pipeline stays in it. Nothing here decides any of that.
 */
import { apiRequest } from '#lib/api-helpers.js';
import { canMoveCard } from '#lib/v2/board-drag.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

/** The lane id standing for "in no stage". A stage id is always a UUID. */
export const UNSTAGED = 'unstaged';

const GREY = '#6B7280';

/**
 * A stage colour is tenant text that ends up in a `style` attribute, so only a
 * plain hex colour gets through. Anything else is drawn grey.
 */
function swatch(value: unknown) {
  return typeof value === 'string' && /^#[0-9a-fA-F]{6}$/.test(value) ? value : GREY;
}

function toCard(lead: Schemas['LeadKanbanCard']) {
  const owner = lead.assigned_to?.[0];
  return {
    id: lead.id,
    name: lead.full_name || lead.title || 'Unnamed lead',
    company: lead.company_name ?? '',
    rating: lead.rating ?? '',
    owner: owner?.user_details?.name || owner?.user_details?.email || '',
    overdue: Boolean(lead.is_follow_up_overdue),
    // The server's word on whether this viewer may move the lead.
    canMove: canMoveCard(lead)
  };
}

function toLane(
  id: string,
  name: string,
  color: string,
  column: { lead_count?: number; leads?: Schemas['LeadKanbanCard'][] },
  wipLimit: number | null = null
) {
  const rows = (column.leads ?? []).map(toCard);
  const total = column.lead_count ?? rows.length;
  return {
    id,
    name,
    color,
    rows,
    count: total,
    truncated: total > rows.length,
    wipLimit,
    // The page cannot import UNSTAGED from a server module, so the lane says.
    unstaged: id === UNSTAGED
  };
}

const EMPTY = { pipelines: [], pipeline: null, lanes: [] };

/**
 * The board for one pipeline. `pipelineId` (from `?pipeline=`) picks it; an
 * absent or unknown id falls back to the first, which the API sorts with the
 * org's default on top. Only an id the API has just listed is ever forwarded,
 * so a hand-edited URL cannot turn into a 400 or a 404 from the kanban call.
 */
export async function getLeadBoard(
  { cookies }: { cookies: Cookies },
  pipelineId: string | null = null
) {
  const listed: Schemas['LeadPipelineListResponse'] = await apiRequest(
    '/leads/pipelines/',
    {},
    { cookies }
  );
  const pipelines: { id: string; name: string }[] = (listed.pipelines ?? []).map((p) => ({
    id: p.id,
    name: p.name
  }));
  if (pipelines.length === 0) return { ...EMPTY };

  const active = pipelines.find((p) => p.id === pipelineId) ?? pipelines[0];
  const query = new URLSearchParams({ pipeline_id: active.id });
  const board: Schemas['LeadKanbanResponse'] = await apiRequest(
    `/leads/kanban/?${query}`,
    {},
    { cookies }
  );

  const stages = [...(board.columns ?? [])].sort((a, b) => a.order - b.order);
  const lanes = [
    toLane(UNSTAGED, 'No stage', GREY, board.unstaged ?? {}),
    ...stages.map((c) => toLane(String(c.id), c.name, swatch(c.color), c, c.wip_limit ?? null))
  ];

  return { pipelines, pipeline: active, lanes };
}

/**
 * Move a lead into a stage, optionally between two cards of that stage.
 * `UNSTAGED` sends `stage_id: null`, which takes the lead out of its pipeline.
 */
export async function moveLead(
  { cookies }: { cookies: Cookies },
  id: string,
  { stageId, aboveId, belowId }: { stageId: string; aboveId?: string; belowId?: string }
): Promise<Schemas['LeadMoveResponse']> {
  return await apiRequest(
    `/leads/${id}/move/`,
    {
      method: 'PATCH',
      body: {
        stage_id: stageId === UNSTAGED ? null : stageId,
        ...(aboveId ? { above_lead_id: aboveId } : {}),
        ...(belowId ? { below_lead_id: belowId } : {})
      }
    },
    { cookies }
  );
}
