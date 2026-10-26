/**
 * Parent and child tickets on a ticket's page (PARITY B3).
 *
 * The phone has had this on `ticket_detail_screen.dart` all along: a parent
 * row, the tree the ticket sits in, link under a parent, detach. The web had
 * two components for it that nothing imported. This module is the part of the
 * web version that is not markup, so it can be tested on its own, the way
 * `close.js` is.
 *
 * Everything the page decides here comes from the API:
 *
 * - The tree is `GET /cases/<id>/tree/`, which starts at the TOP of the tree,
 *   not at this ticket, and names `focus_id`. A node the viewer may not open
 *   arrives redacted (`name: null`, `restricted: true`) and stays in place, so
 *   a readable grandchild under it keeps its real depth.
 * - Whether link and detach are offered is `comment_permission` from the
 *   detail payload, the ticket's write rule, which is the rule `link/` takes.
 * - What may be picked as a parent is the list endpoint's answer, which is
 *   already only tickets this person may open.
 */

import { RESTRICTED_TICKET_NAME } from '#lib/v2/enums.js';
import { apiErrorBody, firstMessage } from '#lib/api-errors.js';
import { findNode, type TreeNode } from './close.js';

/**
 * The tree as rows, top down, for an indented list.
 *
 * A restricted node keeps its status: `/tree/` sends it on purpose, and the
 * phone shows it too. It never gets a name or a link, because opening it would
 * only answer 404.
 *
 * @param root the tree response's `root`
 * @param focusId the ticket this page is about
 */
export function treeRows(
  root: TreeNode | null | undefined,
  focusId: string
): Array<{
  id: string;
  name: string;
  status: string | null;
  depth: number;
  restricted: boolean;
  focus: boolean;
  truncated: boolean;
}> {
  const rows: ReturnType<typeof treeRows> = [];
  const walk = (node: TreeNode, depth: number) => {
    const restricted = Boolean(node.restricted);
    rows.push({
      id: node.id,
      name: restricted ? RESTRICTED_TICKET_NAME : (node.name ?? ''),
      status: node.status ?? null,
      depth,
      restricted,
      focus: node.id === focusId,
      truncated: Boolean(node.truncated)
    });
    for (const child of node.children ?? []) walk(child, depth + 1);
  };
  if (root) walk(root, 0);
  return rows;
}

/**
 * The ticket and everything under it: none of these may become its parent,
 * since that would make a cycle. The API refuses one anyway; this keeps the
 * picker from offering it.
 */
export function subtreeIds(root: TreeNode | null | undefined, id: string): Set<string> {
  const ids = new Set([id]);
  const walk = (node: TreeNode) => {
    for (const child of node.children ?? []) {
      ids.add(child.id);
      walk(child);
    }
  };
  const focus = findNode(root, id);
  if (focus) walk(focus);
  return ids;
}

/**
 * What the "Link under a parent" picker offers: list rows minus this ticket,
 * its own subtree, the parent it already has, and anything merged away (the
 * API refuses a merged parent).
 *
 * @param rows from `listTickets`
 */
export function parentCandidates<R extends { id: string; status: string }>(
  rows: R[],
  { exclude, parentId = null }: { exclude: Set<string>; parentId?: string | null }
): R[] {
  return rows.filter(
    (row) => !exclude.has(row.id) && row.id !== parentId && row.status !== 'Duplicate'
  );
}

/**
 * The sentence to show when `link/` refuses.
 *
 * Its refusals are `{"parent_id": "<sentence>"}` (hidden or missing parent,
 * self, cycle, depth, merged) or `{"detail": "<sentence>"}`, and `apiRequest`
 * would prefix the first with the key. The key means nothing to a person.
 *
 * @param err the error thrown by `apiRequest`
 */
export function linkRefusal(err: unknown, fallback: string) {
  const body = apiErrorBody(err) ?? {};
  for (const said of [body.parent_id, body.detail]) {
    const text = firstMessage(said);
    if (typeof text === 'string' && text.trim()) return text.trim();
  }
  return fallback;
}
