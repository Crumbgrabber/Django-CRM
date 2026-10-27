# Projects

A project is the delivery work between a won deal and the invoice. Tasks, logged time, files and
comments hang off it; the hourly rate fills itself when time is logged; the budget burn shows
live; an admin turns unbilled time, or a share of a fixed fee, into a draft invoice in one
step; and a retainer drafts its invoice each month by itself.

Projects are a module, **Projects**, on for every org by default; an admin can switch it off in
[Modules](../getting-started/modules.md). The code is `backend/projects/`; time and billing reuse
`backend/cases/time_views.py`, `backend/cases/services/billing.py` and
`InvoiceFromTimeEntriesView` in `backend/invoices/api_views.py`.

## The record

| Field | Notes |
| --- | --- |
| `name` | Required |
| `account` | Required: the client. Must be an account the caller may open |
| `deal` | Optional: the deal it came from. Must be a deal the caller may open. Kept as `null` if the deal is deleted |
| `status` | `active` (default), `on_hold`, `completed`, `cancelled` |
| `billing_type` | `time_and_materials` (default), `fixed_fee`, `non_billable`, `retainer` ([Retainers](#retainers)) |
| `currency` | The org's currency by default |
| `budget_hours`, `budget_amount`, `hourly_rate` | Each optional, 0 or more |
| `start_date`, `due_date` | Optional; the due date cannot be before the start date |
| `assigned_to` | The project's people: active members of the org |
| `rates` | One rate per person on this project, ahead of `hourly_rate` |
| `retainer_fee`, `retainer_hours`, `retainer_rollover`, `retainer_overage_rate`, `retainer_carried_hours` | The retainer's terms; see [Retainers](#retainers) |
| `description`, `tags`, `custom_fields` | As on every record; custom fields target `Project` |

### Who sees what

The deal rules ([Opportunities](../api/opportunities.md)). Admins see every project; anyone else
sees the projects they created or are assigned to, and may edit them. Admins and the creator may
delete one; an assignee may not (`403`). A retainer project only an admin may delete, as only an
admin sets the status that ends its billing. A project the caller may not open answers `404`, exactly
like an id that does not exist, and so does another org's. Rates and budgets are visible to
whoever sees the project, but `burn.invoiced_amount` only to admins. Billing a project is for
admins only.

### Money is set by admins

`billing_type`, `currency`, `budget_hours`, `budget_amount`, `hourly_rate`, `rates` and the five
writable retainer fields are written only by org admins. On a retainer project, `status` is too,
since it decides which months are billed. For anyone else they are read-only and silently
ignored, so a member's new project gets the defaults: time and materials, the org's currency, no
budgets, no rates and no retainer.
Anyone who may create a project chooses its account; moving an existing project to another
account is for admins only, and ignored for anyone else.

The currency cannot change once the project has any time entry or any invoice, even for an
admin: `400` `{"currency": ["The currency cannot change once the project has time or
invoices."]}`. Sending the current currency back is fine.

### Closing a project

Set its status to `completed` or `cancelled`: that is the usual way to close one, and it keeps
everything in place. An account cannot be deleted while it has a project: the delete answers
`409` with "This account can't be deleted while it still has projects, invoices, estimates or
recurring invoices linked to it." While Projects is switched off, the refusal names the module
instead, as for every off module. Deleting a project keeps its logged time, its invoices and its tasks, with
the link to the project cleared, so billed history is never lost. A time entry left this way has
neither a ticket nor a project; the timesheet, the time report and its export list it as having
none, and it can no longer be billed.

## The API

All routes are under `/api/projects/`. Errors use `{"error": true, "errors": {...}}`, and a
missing or hidden project answers `404` `{"error": true, "errors": "Project not found."}`.

| Route | What it does |
| --- | --- |
| `GET /api/projects/` | `{"projects": [...], "count": N}`, newest first. Filters: `status`, `account`, `assigned_to` (a profile id), `search` (name, any case), `limit` (default 50, at most 200) and `offset` |
| `POST /api/projects/` | Create; `201` `{"error": false, "id": "<uuid>", "project": <detail>}` |
| `GET /api/projects/<id>/` | The detail |
| `PATCH /api/projects/<id>/` | Any create field; `rates`, when sent, replaces the whole list. Answers like create, with `200` |
| `DELETE /api/projects/<id>/` | `204`; see [Closing a project](#closing-a-project) |
| `POST /api/projects/<id>/` | Adds a comment (`comment`), a file (`project_attachment`), or both, as on a deal, and answers the detail |
| `GET /api/projects/from-deal/<deal_id>/` | A draft for the new-project form, nothing saved |
| `POST /api/projects/<id>/retainer/bill/` | Bills a retainer's month now; see [Bill this month](#bill-this-month) |

A list row carries `id`, `name`, `account` (`{"id", "name"}`), `deal` (`{"id", "name"}` or
`null`), `status`, `billing_type`, `currency`, `budget_hours`, `budget_amount`, `hourly_rate`,
`start_date`, `due_date`, `assigned_to` (profiles), `tags`, `burn`, `created_at` and
`updated_at`, and the retainer fields: the five writable ones plus `retainer_next_month` and
`retainer_last_month`. The detail adds `description`, `custom_fields`, `retainer_usage`, `rates`
(`[{"profile": <profile>, "hourly_rate"}]`), `comments`, `attachments`, `invoices` (newest first,
the ones the caller may open, `[]` while Invoices is off), `estimate` (see
[From an accepted estimate](#from-an-accepted-estimate)), `can_edit`, `can_delete` and
`can_bill`.

`assigned_to` and each rate's `profile` must be active members of the org, with at most one rate
per person; anything else is a `400` naming the field. An edit may send back people already on
the project (assigned, or holding a rate) after they were deactivated; only people being added
must be active. A refusal names the person, and never shows an id.

### From a won deal

A won deal offers **Start a project**. `GET /api/projects/from-deal/<deal_id>/` answers the
deal's name, its account and the deal itself (each `{"id", "name"}`, the account `null` when the
deal has none), its currency (else the org's), the ids of its active assignees, and
`billing_type` `fixed_fee` with the deal amount as `budget_amount` when the deal has an amount,
else `time_and_materials` with `null`. A deal the caller cannot see answers `404`. Nothing is
created until the form is saved.

### From an accepted estimate

An estimate can ask for a project when the client accepts it ([Proposals](proposals.md)). On
acceptance the server creates it: named after the estimate's title, for its account, deal and
currency, with the estimate's `project_billing_type`, its pre-tax total as `budget_amount` (none
for `non_billable`), status `active`, the acceptance day (the org's) as `start_date`, the
estimate's creator as `created_by`, and the estimate's active assignees and creator as its people.
It has no `hourly_rate` and no `rates`: an admin sets them afterwards. Nothing is created while
Projects is off. Raising the invoice before the client accepts starts the project the same way.

The project's detail carries `estimate`, `{"id", "estimate_number"}` of the estimate that started
it, or `null`: also `null` while Invoices is off and for a caller who may not open that estimate.
An invoice raised from the estimate afterwards carries the project too.

### Budget burn

Each project carries `burn`:

| Key | Meaning |
| --- | --- |
| `logged_hours` | Every stopped entry on the project, whoever logged it |
| `billable_hours` | The billable ones |
| `billable_value` | Billable entries with a rate, at each entry's own rate |
| `unbilled_value` | The same, not yet on an invoice |
| `invoiced_amount` | The project's invoices that are not Cancelled, before tax (subtotal less the invoice's discount), so it compares with the fee; `null` for anyone but an admin, and while Invoices is off |
| `hours_percent` | `logged_hours` over `budget_hours`, a whole number; `null` without that budget |
| `amount_percent` | `billable_value` over `budget_amount`, a whole number; `null` without that budget |

Hours and money are strings with two places. Money counts only the project's currency, so two
currencies are never added together. A running timer counts once it is stopped.

At 80% and again at 100% of `budget_hours` or `budget_amount`, each person on the project and
each org admin gets one in-app notification per level and kind, ever: verb `project.budget`,
`data` `{"kind": "hours" | "amount", "percent": 80 | 100, "project": "<name>"}`, link
`/projects/<id>`. Usage that jumps past both levels at once sends only the 100% one. The check
runs when time is logged, a timer stops (by hand or when a forgotten timer is stopped
automatically), an entry is edited and a project is saved, and not while Projects is off.

## Tasks on a project

A task gains a fifth kind of parent, `project`, on read and write; a task still has at most one
parent. The task list and the task board take `?project=<id>`. See [Tasks](../api/tasks.md).

## Time on a project

Time hangs off a ticket or a project, never both.

- `GET` and `POST /api/projects/<id>/time-entries/` and `POST /api/projects/<id>/time-entries/start/`
  take the same bodies and answer as the ticket routes, plus an optional `task`, which must be a
  task on this project that the caller may open (else `400`). Logging time needs edit access to the project, which on a
  project is the read rule. A member reads their own entries, an admin everyone's.
- **The rate fills itself.** An entry created without `hourly_rate` takes the person's rate on
  the project, else the project's `hourly_rate`, else none. Only an admin may type a rate on
  project time, on create or edit; a member's typed rate is ignored. Its `currency` is always the
  project's. Ticket time keeps today's typed rate.
- **Billable by default.** On a project, time is billable unless `billable` is sent as `false`.
  On a `non_billable` project it is never billable, whatever is sent, on create, timer start and
  edit. Ticket time keeps today's default (not billable when not sent).
- A timer start reads `billable` as `true` or `false` (a JSON boolean or those two strings); any
  other value is `400` `{"billable": ["Send true or false."]}`, on ticket and project routes
  alike.
- One running timer per person, on a ticket or a project: a second start answers `409` with
  `running_entry_id`, `running_case_id` and `running_project_id` (each `null` when it does not
  apply).
- Stop, edit and delete stay on `/api/time-entries/<id>/`. An edit may set `task` on a project's
  entry; a ticket's entry cannot name one.

A time entry read carries `case` (`null` for project time), `project`, `project_name` and `task`.

### Reports

`GET /api/time-entries/report/` takes `group_by=agent|ticket|project|account` and the filters
`profile`, `account`, `project` and `billable`. An entry's account is its ticket's or its
project's. Time on no ticket, no project or no account is one named row (`No ticket`,
`No project`, `No account`) with a `null` key. Every row carries `billable_minutes`; rows by agent
also carry `billable_share`, billable minutes over all minutes (a number from 0 to 1, two places,
or `null` with no time): the utilisation figure. The CSV export has a `Project` column after
`Ticket`.

## Bill the time

`POST /api/invoices/from-time-entries/`, admins only (`403` for anyone else, before the body is
read). Send either `account_id` or `project_id`:

- **`account_id` and `entry_ids`** bills ticket time, as before: every entry must be on a ticket
  for that account. Needs Tickets.
- **`project_id`** bills a project. Without `entry_ids` it takes every stopped, billable, unbilled
  entry on the project started on or before `up_to` (a date, today by default); with them, each
  must be on the project. Needs Projects.

`group_by` is `entry` (the default, one line per entry), `person`, `task` (entries without a task
share one line) or `single`. A grouped line's quantity is the summed hours and its unit price the
rate its entries share; entries in one group with different rates split into one line per rate.

The answer is `201` with `invoice_id`, `invoice_number`, `currency`, `line_count`, `entry_ids`
and `project_id` (`null` when billing an account). The draft invoice carries `project`, and its
entries are marked billed, so a billed entry is never billed twice: naming one is a `400`, and a
second run by date passes it over. Another org's project or account answers `404`.

`GET /api/projects/<id>/unbilled/?up_to=<date>` (admins only) previews the same selection:
`{"entry_count", "hours", "value", "currency", "unrated_count"}`. `unrated_count` is how many of
those entries have no rate; they bill at 0.

### Invoice an amount

For a fixed fee, `POST /api/projects/<id>/invoice-amount/` (admins only) takes exactly one of
`amount` (more than 0) or `percent` (more than 0, at most 100, of `budget_amount`, which must be
set), and an optional `description` (default `<project name>, fixed fee`). It makes a one-line
Draft invoice for the project's account, in the project's currency, carrying `project`, and
answers `201` `{"invoice_id", "invoice_number"}`. The project shows admins the total invoiced
against the fee in `burn.invoiced_amount`. Percent invoices are not capped cumulatively: each one
is checked on its own, so several can add up to more than the fee.

A retainer project bills by the month instead ([Retainers](#retainers)); the web and phone apps
do not offer **Bill time** on one, though the endpoint does not refuse it.

### Cancelling frees the time

Cancelling an invoice frees its time entries, so the time can be billed again, unless a payment
was recorded on it: then the entries stay billed, since that time was paid for. Every path that
sets an invoice to Cancelled saves through `Invoice.save()`, which does it: the cancel endpoint,
the Django admin and any script.

## Retainers

A retainer is a monthly fee for a client, with an optional allowance of hours. Set
`billing_type` to `retainer` (admins only) with these fields, each on the list row and the detail:

| Field | Notes |
| --- | --- |
| `retainer_fee` | The monthly fee, at least `0.01`. Required on a retainer: `400` `{"retainer_fee": ["Set the monthly fee."]}` |
| `retainer_hours` | Hours the fee includes each month, from 0 to 744 (the hours in the longest month): `400` `{"retainer_hours": ["At most 744 hours, the hours in a month."]}` above that. `null` is no allowance: the fee alone, never an overage |
| `retainer_rollover` | Whether unused hours carry to the next month. Default `false` |
| `retainer_overage_rate` | The hourly rate for hours over the allowance, 0 or more. Required on a retainer whenever `retainer_hours` is set: `400` `{"retainer_overage_rate": ["Set the rate for hours over the allowance."]}` |
| `retainer_carried_hours` | Unused hours carried into the next invoice, 0 or more, default `0.00`. Writable, so an admin can correct or clear it |
| `retainer_next_month` | Read-only: the first day of the month the next retainer invoice bills, or `null` |
| `retainer_last_month` | Read-only: the first day of the last month to bill, or `null` while the retainer is open |

The checks apply when the saved billing type is `retainer`, judged against what is stored, so
switching an existing project to a retainer needs its fee too. Other billing types keep any
retainer values unused. Switching away from a retainer and back keeps the fee, hours, rollover and
rate; the months never move backwards, so a month already billed stays billed, and the carried
hours restart at 0.

### Months

Months are calendar months in the org's timezone. Each create and edit applies three rules:

1. **Becoming a retainer** (created as one, or switched to one): billing starts with the latest of
   the current month, the month of `start_date` and the month it was already set to bill next, with
   no carried hours. A project that is not active then bills nothing until it becomes active.
2. **Leaving active** (to on hold, completed or cancelled): the current month is the last one, and
   it is still billed in full.
3. **Back to active**: first, every month still owed (from `retainer_next_month` through
   `retainer_last_month`, once it has ended) is drafted, as the admin's invoice. Then billing
   restarts from the current month (or a later month, when that one is already set to bill next),
   and the months in between are not billed. Paused and resumed within one month, nothing is
   drafted.

There is no proration: a partial first or last month is billed in full, and the admin edits the
draft if needed.

### The monthly invoice

Once a month has ended in the org's timezone, a scheduled job drafts its invoice, within the hour
after midnight there. Each invoice is a Draft for the project's account and currency, linked to the
project, titled `<project name>, retainer <Month YYYY>`, with no tax rate, and with:

- `<Month YYYY> retainer`: quantity 1 at `retainer_fee`;
- `Hours over the allowance`, when the month's time exceeds it: the extra hours at
  `retainer_overage_rate`.

The month's time is every stopped, billable, unbilled entry on the project started on or before
the month's last day. While Timesheet is switched off its time is out of sight: an invoice then
holds the fee alone, takes no entries and leaves the carried hours as they are, and
`retainer_usage` shows no hours used. Time logged late (an entry made on 3 November for 30 October), and time
freed by cancelling an invoice, counts in the next invoice drafted, against that month's
allowance; a month already invoiced is never drafted again. A timer still running when the month
ends counts once it is stopped, in the next invoice. The entries are marked billed by the invoice.

Hours are worked out from minutes: three 20-minute entries against a half-hour allowance are 0.50
hours over. The allowance is `retainer_hours`, plus `retainer_carried_hours` when rollover is on.
With rollover on, what is left of the allowance (to two places) carries to the next month, with no
cap and never as money; with it off, nothing carries. Carried hours are spent before any overage.

The job drafts with no creator, so only admins see the invoice until it is assigned. Each of the
org's active admins gets an in-app notification per invoice: verb `project.retainer_invoice`,
`data` `{"project": "<name>", "month": "YYYY-MM", "invoice_number"}`, link `/invoices/<id>`.

Months that ended while the scheduler was not running are drafted in order on its next run, each
passing its unused hours on to the next. The scheduled job skips a month that ended while Projects
or Invoices was switched off rather than drafting it late. It judges that from when the module
last came back on: a month is skipped when it ended before then, so switching a module off and on
again just after midnight skips the month that had just ended. **Bill this month**, a deliberate
admin action, applies no such skip: clicked before the job's next run, it drafts that month.
Nothing runs without a Celery beat process
([Email and Celery](../self-hosting/email-and-celery.md#running-a-worker)).

### Bill this month

`POST /api/projects/<id>/retainer/bill/`, admins only (`403` for anyone else, before the project
is looked up). It bills `retainer_next_month` now: an ended month the job has not drafted yet, or
the open month through today. The body is optional: `{"month": "YYYY-MM"}` names the month the
caller showed, and is refused as already billed when that is no longer the month billing next, so a
page loaded before the job drafted a month never bills the month after by mistake. A malformed
month is `400` `{"error": true, "errors": {"month": ["Send a month as YYYY-MM."]}}`. The invoice is the same as the job's, except that the admin
is its creator, its contact is the account's newest contact the admin may open, and nobody is
notified. It answers `201` `{"invoice_id", "invoice_number", "month": "YYYY-MM"}`; the open month
billed this way is not drafted again when it ends.

Refusals are `400` `{"error": true, "message": ...}`:

- "This project is not on a retainer."
- "This retainer is not running. Make the project active to bill it." (not active, and nothing
  owed: `retainer_next_month` is past `retainer_last_month`)
- "This retainer has ended." (active, yet past `retainer_last_month`)
- "This retainer starts in <Month YYYY>." (`retainer_next_month` is a later month, the month of
  `start_date`)
- "This month is already billed." (`retainer_next_month` is a later month otherwise, or the month
  sent or read was billed by the job or another click meanwhile)

A hidden or another org's project, or one deleted while the request ran, is `404`.

The detail's `retainer_usage` is `null` unless the project is a retainer, else what billing
`retainer_next_month` would count today:

| Key | Meaning |
| --- | --- |
| `month` | `retainer_next_month` as `YYYY-MM` |
| `used_hours` | The unbilled billable hours that month's invoice would take, through today |
| `available_hours` | The allowance, plus carried hours with rollover; `null` with no allowance |
| `overage_hours` | Hours over the allowance so far, `0.00` with none |
| `billable_now` | Whether **Bill this month** would succeed for an admin right now (Invoices on included) |

## Modules

| Route | Needs |
| --- | --- |
| `/api/projects/...` | Projects |
| `/api/projects/<id>/time-entries/...` | Projects and Timesheet |
| `/api/projects/<id>/unbilled/` | Projects, Invoices and Timesheet |
| `/api/projects/<id>/invoice-amount/` | Projects and Invoices |
| `/api/projects/<id>/retainer/bill/` | Projects and Invoices |
| `/api/projects/from-deal/<deal_id>/` | Projects and Pipeline |
| `/api/time-entries/...` | Timesheet, and Tickets or Projects |
| `/api/invoices/from-time-entries/` | Invoices, Timesheet, and Tickets or Projects |

Timesheet no longer needs Tickets. While a module is off its routes answer as every off module
does ([Modules (API)](../api/modules.md#what-an-off-module-answers)).
