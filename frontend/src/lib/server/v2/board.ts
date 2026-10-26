/**
 * Kanban boards: the wiring behind /v2/tasks/board.
 *
 * Server-only. A board is read in two calls: `GET /boards/?archived=false` for
 * the picker (and to resolve the active board), then
 * `GET /boards/<id>/columns/`, which nests each column's cards. Those are
 * flattened into the `{ board, boards, columns, tasks }` shape the page joins
 * by `column_id`. The totals the page shows are derived on the page from the
 * live lanes, so a drag updates them without a round-trip.
 *
 * Three writes: a card move (`PUT /boards/tasks/<id>/` with the new `column`
 * and `order`, server-validated to a sibling column of the same board), adding
 * a card (`POST /boards/columns/<id>/tasks/`, any board member), and adding a
 * column (`POST /boards/<id>/columns/`, owner/admin only). The page cannot do
 * any of these anywhere the backend wouldn't, the org, the board and the role
 * are all checked server-side; this layer only carries the request.
 */
import { apiRequest, type FormBody } from '#lib/api-helpers.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

/** A board card's assignee → `{ id, name }`. ProfileSerializer nests the
 *  display name under `user_details`; fall back to the email, then a label. */
function assignee(p: Schemas['Profile']) {
  const d = p.user_details;
  return { id: p.id, name: d?.name || d?.email || 'Unknown' };
}

/** One nested BoardTask → the flat card shape the board renders. */
function toCard(t: Schemas['BoardTask'], columnId: string) {
  return {
    id: t.id,
    column_id: columnId,
    order: t.order ?? 0,
    title: t.title,
    priority: t.priority,
    due_date: t.due_date ?? null,
    completed_at: t.completed_at ?? null,
    account: t.account ? { id: t.account.id, name: t.account.name } : null,
    assigned_to: (t.assigned_to || []).map(assignee)
  };
}

const EMPTY = { board: null, boards: [], columns: [], tasks: [] };

/**
 * The active board shaped for the page. `boardId` (from `?board=`) selects which
 * board; absent or unknown falls back to the most recent one. Returns an empty
 * shape (no crash) when the org has no boards yet.
 */
export async function getBoard({
  cookies,
  boardId = null
}: {
  cookies: Cookies;
  boardId?: string | null;
}) {
  const listResp: Schemas['BoardListResponse'] = await apiRequest(
    '/boards/?archived=false',
    {},
    { cookies }
  );
  const results = listResp.results || [];
  if (results.length === 0) return { ...EMPTY };

  const active = (boardId && results.find((b) => b.id === boardId)) || results[0];
  const cols: Schemas['BoardColumn'][] = await apiRequest(
    `/boards/${active.id}/columns/`,
    {},
    { cookies }
  );

  const sorted = [...cols].sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
  const columns = sorted.map((c) => ({
    id: c.id,
    name: c.name,
    order: c.order,
    limit: c.limit ?? null,
    color: c.color
  }));

  const tasks: ReturnType<typeof toCard>[] = [];
  for (const c of sorted) {
    for (const t of c.tasks || []) tasks.push(toCard(t, c.id));
  }

  return {
    board: { id: active.id, name: active.name, description: active.description || '' },
    boards: results.map((b) => ({
      id: b.id,
      name: b.name,
      is_archived: b.is_archived,
      task_count: b.task_count
    })),
    columns,
    tasks,
    // Owner/admin may add or reshape columns; a plain member may not (the
    // backend enforces it. This only decides whether to *offer* the control,
    // so a member isn't shown a button that would 403). Adding a *card* needs
    // only membership, and anyone who can see this board already has it.
    canManageColumns: active.my_role === 'owner' || active.my_role === 'admin'
  };
}

/**
 * Add a column to a board. Owner/admin only, enforced by the backend
 * (`BoardColumnListCreateView`); `board` and `org` are set there from the URL
 * and the JWT, never from this body. `order` places the new lane at the end,
 * the page passes the next index, since a column defaulting to 0 would jump to
 * the front of the board.
 */
export async function createColumn(
  { cookies }: { cookies: Cookies },
  boardId: string,
  { name, color, order }: { name: string; color?: string; order?: number }
): Promise<Schemas['BoardColumn']> {
  const body: Schemas['BoardColumnRequest'] = { name };
  if (color) body.color = color;
  if (order !== undefined && Number.isFinite(order)) body.order = order;
  return apiRequest(`/boards/${boardId}/columns/`, { method: 'POST', body }, { cookies });
}

/**
 * Create a board.
 *
 * `BoardListCreateView.post` derives `org`, `owner` and `created_by` from the
 * JWT, enrols the caller as the owner member, and, unless told otherwise,
 * seeds the three default columns. So the whole write surface is a name and an
 * optional description, and a fresh board is usable the moment it exists.
 *
 * Until this existed no client could create one. The page said to use the
 * mobile app, which has no board feature at all, so an org that had never been
 * given a board through the API could not get one.
 */
export async function createBoard(
  { cookies }: { cookies: Cookies },
  { name, description }: { name: string; description?: string }
): Promise<Schemas['Board']> {
  const body: Schemas['BoardRequest'] = { name };
  if (description) body.description = description;
  return apiRequest('/boards/', { method: 'POST', body }, { cookies });
}

/**
 * Add a card to a column. Any board member may; the backend derives the card's
 * `column`, `org` and `created_by` from the URL and the JWT. The write surface
 * is deliberately narrow (title, description, priority) matching
 * `BoardTaskSerializer`, so nothing here can stamp a card into another board.
 */
export async function createCard(
  { cookies }: { cookies: Cookies },
  columnId: string,
  { title, description, priority }: { title: string; description?: string; priority?: string }
): Promise<Schemas['BoardTask']> {
  // `priority` is the form's string; the API checks it is one it knows.
  const body: FormBody<Schemas['BoardTaskRequest']> = { title };
  if (description) body.description = description;
  if (priority) body.priority = priority;
  return apiRequest(`/boards/columns/${columnId}/tasks/`, { method: 'POST', body }, { cookies });
}

/**
 * Move a card: relocate it to `column` and place it at `order`. The backend
 * validates the column and resequences the lane, so the returned card is the
 * source of truth on the next load.
 *
 * @param id card id
 */
export async function moveBoardTask(
  { cookies }: { cookies: Cookies },
  id: string,
  { column, order }: { column: string; order: number }
): Promise<Schemas['BoardTask']> {
  return apiRequest(
    `/boards/tasks/${id}/`,
    { method: 'PUT', body: { column, order } satisfies Schemas['PatchedBoardTaskMoveRequest'] },
    { cookies }
  );
}
