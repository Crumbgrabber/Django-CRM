# Proposals

An estimate becomes a proposal by carrying three optional things: an introduction above its
lines, a deposit asked for on acceptance, and a project to start when the client accepts. The
client accepts on the public estimate page, as before, by typing a name and an email; the server
then starts the project, drafts the deposit invoice, links both to the estimate and tells the
estimate's people. Nothing is sent to the client automatically.

Estimates live in the **Invoices** module. The code is `backend/invoices/proposals.py`, called from
`PublicEstimateAcceptView` and `PublicEstimateDeclineView` in `backend/invoices/public_views.py`.
The API is in [Invoices and estimates](../api/invoices.md#proposals).

## On the estimate

| Field | Notes |
| --- | --- |
| `introduction` | Plain text, up to 5,000 characters. Shown above the lines on the public page and the PDF with its line breaks, never as HTML |
| `deposit_percent` | More than 0 and at most 100, or `null` for no deposit. Fixed once the estimate leaves Draft, like its lines |
| `start_project` | Start a project when the client accepts. Needs an account and the Projects module |
| `project_billing_type` | The started project's billing type: `fixed_fee` (default), `time_and_materials` or `non_billable` |

Only an org admin can turn on `start_project` or choose the billing type, because only an admin
sets a project's money fields ([Projects](projects.md#money-is-set-by-admins)). Anyone else who
changes either is refused with "Only an admin can start a project from an estimate." Sending back
what is stored is not a change, so a member can still edit the rest of an estimate an admin set up.

## The deposit

The deposit is a share of the estimate's pre-tax total (its subtotal less its document discount,
each to the cent), rounded half up to the cent, with the estimate's tax rate charged on it as an
invoice charges tax. One helper works it out, and the public page, the PDF, the estimates list and
the deposit invoice all use it, so the amount the client is shown is the amount the invoice bills.
A deposit that would total 0.00 (a tiny percentage of a small total, or an estimate discounted to
nothing) is no deposit: none is shown and none is drafted.

## When the client accepts

In the same transaction as the acceptance, so a failure leaves the estimate unaccepted and nothing
made, and the client can try again:

1. **The project**, when `start_project` is set and Projects is on. It is named after the
   estimate's title (or "<account>, estimate <number>" without one), for the estimate's account,
   deal and currency, with `project_billing_type`, the pre-tax total as its budget (none for a
   non-billable project), status active and today as its start date. Its people are the estimate's
   active assignees and its creator. No rates are set: an admin adds them, as
   [Projects](projects.md#money-is-set-by-admins) requires.
2. **The deposit invoice**, when there is a deposit: a Draft for the estimate's account,
   contact, client details, deal and currency, linked to the project when one was started, with
   one line "Deposit: <percent>% of estimate <number>, <title>". Its people and teams are the
   estimate's. It is never sent automatically: someone reviews it and sends it.
3. Both are linked to the estimate (`project`, `deposit_invoice`). The deposit is not the
   conversion: **Raise invoice** stays available.
4. **The estimate's people are told**: its creator and active assignees, or the org's admins when
   there are none.

Acceptance happens once, so nothing is made twice. Declining tells the same people and makes
nothing.

## Raising the full invoice

Raising the invoice from an estimate bills every line and carries its project. When the invoice is
raised before the client accepts, an estimate set to start a project starts it then, exactly as
acceptance would, with no deposit (the whole estimate is being invoiced) and no notification; the
client can no longer accept it, since raising the invoice marks it accepted. After the client has
accepted, the invoice carries the project acceptance started.
The deposit is not taken off: invoice lines cannot be negative and invoices have no credits, so the
person removes it by editing the draft before sending it. Both clients name the deposit invoice
before raising, so it is not missed.
