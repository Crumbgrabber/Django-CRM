import { getTimeReport } from '#lib/server/v2/timesheet.js';
import { getModules } from '#lib/server/v2/modules.js';
import { isOn } from '#lib/v2/modules.js';
import { isUuid } from '#lib/v2/projects.js';

/**
 * Where the time went, over a window the URL carries.
 *
 * Every filter is a query parameter and the filter bar is a plain GET form, so
 * a report is a link: it can be bookmarked, sent to whoever asked for it, and
 * reloaded without re-picking three dropdowns. That is also what lets the
 * "Export CSV" anchor be the same query string pointed at the proxy.
 *
 * Nothing is validated here beyond what `getTimeReport` checks, because the
 * API decides what this caller may see: an agent gets their own time, an admin
 * gets the org's, and asking for someone else's is refused there. Grouping by
 * project, and `?project=` (one project's time, from its page), are offered
 * only while Projects is on.
 *
 * @type {import('./$types').PageServerLoad}
 */
export async function load(event) {
  const { cookies, url } = event;
  const projectsOn = isOn((await getModules(event))?.modules ?? null, 'projects');
  const project = url.searchParams.get('project');
  const filters = {
    start: url.searchParams.get('start') || undefined,
    end: url.searchParams.get('end') || undefined,
    group_by: url.searchParams.get('group_by') || undefined,
    billable: url.searchParams.get('billable') || undefined,
    project: projectsOn && isUuid(project) ? /** @type {string} */ (project) : undefined
  };

  const { report } = await getTimeReport({ cookies }, filters, { projectsOn });

  // The window comes back from the API rather than being echoed from the
  // request: asked for without one, it picks the last 30 days, and the date
  // inputs have to show the days actually reported on.
  return {
    report,
    projectsOn,
    filters: { ...filters, start: report.start, end: report.end }
  };
}
