# Projects

A project is the delivery work between a won deal and the invoice. Tasks, logged time, files and
comments hang off it; the hourly rate fills itself when time is logged; the budget burn shows
live; and an admin turns unbilled time, or a share of a fixed fee, into a draft invoice in one
step.

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
| `billing_type` | `time_and_materials` (default), `fixed_fee`, `non_billable` |
| `currency` | The org's currency by default |
| `budget_hours`, `budget_amount`, `hourly_rate` | Each optional, 0 or more |
| `start_date`, `due_date` | Optional; the due date cannot be before the start date |
| `assigned_to` | The project's people: active members of the org |
| `rates` | One rate per person on this project, ahead of `hourly_rate` |
| `description`, `tags`, `custom_fields` | As on every record; custom fields target `Project` |

### Who sees what

The deal rules ([Opportunities](../api/opportunities.md)). Admins see every project; anyone else
sees the projects they created or are assigned to, and may edit them. Admins and the creator may
delete one; an assignee may not (`403`). A project the caller may not open answers `404`, exactly
like an id that does not exist, and so does another org's. Rates and budgets are visible to
whoever sees the project, but `burn.invoiced_amount` only to admins. Billing a project is for
admins only.

### Money is set by admins

`billing_type`, `currency`, `budget_hours`, `budget_amount`, `hourly_rate` and `rates` are written
only by org admins. For anyone else they are read-only and silently ignored, so a member's new
project gets the defaults: time and materials, the org's currency, no budgets and no rates.
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

A list row carries `id`, `name`, `account` (`{"id", "name"}`), `deal` (`{"id", "name"}` or
`null`), `status`, `billing_type`, `currency`, `budget_hours`, `budget_amount`, `hourly_rate`,
`start_date`, `due_date`, `assigned_to` (profiles), `tags`, `burn`, `created_at` and
`updated_at`. The detail adds `description`, `custom_fields`, `rates`
(`[{"profile": <profile>, "hourly_rate"}]`), `comments`, `attachments`, `invoices` (newest first,
the ones the caller may open, `[]` while Invoices is off), `can_edit`, `can_delete` and
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

### Budget burn

Each project carries `burn`:

| Key | Meaning |
| --- | --- |
| `logged_hours` | Every stopped entry on the project, whoever logged it |
| `billable_hours` | The billable ones |
| `billable_value` | Billable entries with a rate, at each entry's own rate |
| `unbilled_value` | The same, not yet on an invoice |
| `invoiced_amount` | The project's invoices that are not Cancelled; `null` for anyone but an admin, and while Invoices is off |
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

### Cancelling frees the time

Cancelling an invoice frees its time entries, so the time can be billed again, unless a payment
was recorded on it: then the entries stay billed, since that time was paid for. Every path that
sets an invoice to Cancelled saves through `Invoice.save()`, which does it: the cancel endpoint,
the Django admin and any script.

## Modules

| Route | Needs |
| --- | --- |
| `/api/projects/...` | Projects |
| `/api/projects/<id>/time-entries/...` | Projects and Timesheet |
| `/api/projects/<id>/unbilled/` | Projects, Invoices and Timesheet |
| `/api/projects/<id>/invoice-amount/` | Projects and Invoices |
| `/api/projects/from-deal/<deal_id>/` | Projects and Pipeline |
| `/api/time-entries/...` | Timesheet, and Tickets or Projects |
| `/api/invoices/from-time-entries/` | Invoices, Timesheet, and Tickets or Projects |

Timesheet no longer needs Tickets. While a module is off its routes answer as every off module
does ([Modules (API)](../api/modules.md#what-an-off-module-answers)).
