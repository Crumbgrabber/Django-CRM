"""Helpers that turn billable :class:`cases.models.TimeEntry` rows into
draft :class:`invoices.models.InvoiceLineItem` shapes.

Kept in ``cases/services/`` so the cross-app glue lives on the cases side
of the boundary, the invoices app only consumes these dicts. Reach over
to ``invoices/api_views.py`` :class:`InvoiceFromTimeEntriesView` for the
actual endpoint that calls this helper.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Iterable, List, Tuple

GROUPINGS = ("entry", "person", "task", "single")


class TimeEntryInvoicingError(ValueError):
    """Raised when a set of time entries cannot be converted into invoice lines."""


def _entry_label(entry):
    parent = entry.case if entry.case_id else entry.project
    parent_name = parent.name if parent is not None else "Time entry"
    body = entry.description.strip() if entry.description else ""
    return f"{parent_name}, {body}" if body else parent_name


def _group_label(entry, group_by, single_label):
    if group_by == "person":
        user = entry.profile.user
        return user.name or user.email
    if group_by == "task":
        return entry.task.title if entry.task_id else "Other time"
    return single_label


def build_invoice_lines_from_entries(
    entries, group_by="entry", single_label="Time"
) -> Tuple[str, List[dict]]:
    """Validate ``entries`` and return ``(currency, lines)``.

    Each line is a dict suitable for ``InvoiceLineItem.objects.create(...)``
    keyword arguments (sans ``invoice``/``org`` which the caller injects).

    ``group_by`` is one of `GROUPINGS`: one line per entry, or one per person,
    per task (entries with no task share a line) or for everything, named
    ``single_label``. A grouped line's quantity is its summed hours and its
    unit price the rate its entries share; a group whose entries carry
    different rates becomes one line per rate.

    Rejects (raising :class:`TimeEntryInvoicingError`):

    * Empty input.
    * Mixed currencies: single invoices stay single-currency.
    * Already-invoiced entries.
    * Unstopped (running) entries.
    * Non-billable entries.
    """
    if group_by not in GROUPINGS:
        raise TimeEntryInvoicingError(
            f"group_by must be one of {', '.join(GROUPINGS)}."
        )
    entries = sorted(entries, key=lambda e: (e.started_at, str(e.id)))
    if not entries:
        raise TimeEntryInvoicingError("No time entries supplied.")

    currencies = {e.currency for e in entries}
    if len(currencies) > 1:
        raise TimeEntryInvoicingError(
            f"Cannot invoice entries in multiple currencies: {sorted(currencies)}."
        )
    currency = next(iter(currencies))

    for entry in entries:
        if entry.invoice_id is not None:
            raise TimeEntryInvoicingError(
                f"Time entry {entry.id} has already been invoiced."
            )
        if entry.ended_at is None:
            raise TimeEntryInvoicingError(
                f"Time entry {entry.id} is still running and cannot be invoiced."
            )
        if not entry.billable:
            raise TimeEntryInvoicingError(
                f"Time entry {entry.id} is not marked billable."
            )

    # (label, minutes, rate) per line, in the order lines first appear.
    groups: dict = {}
    for entry in entries:
        rate = entry.hourly_rate if entry.hourly_rate is not None else Decimal("0")
        if group_by == "entry":
            key, label = entry.id, _entry_label(entry)
        else:
            label = _group_label(entry, group_by, single_label)
            group_key = {
                "person": entry.profile_id,
                "task": entry.task_id,
                "single": None,
            }[group_by]
            key = (group_key, rate)
        line = groups.setdefault(key, {"label": label, "minutes": 0, "rate": rate})
        line["minutes"] += entry.duration_minutes

    lines: List[dict] = []
    for index, line in enumerate(groups.values()):
        hours = (Decimal(line["minutes"]) / Decimal(60)).quantize(Decimal("0.01"))
        lines.append(
            {
                "name": line["label"][:255],
                "description": line["label"][:500],
                "quantity": hours,
                "unit_price": line["rate"],
                "order": index,
            }
        )
    return currency, lines


def attach_entries_to_invoice(entries: Iterable, invoice) -> int:
    """Set ``invoice`` on each entry. Returns the count updated."""
    from cases.models import TimeEntry

    ids = [e.id for e in entries]
    return TimeEntry.objects.filter(id__in=ids).update(invoice=invoice)
