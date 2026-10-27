"""An estimate as a proposal: the deposit it asks for, and what the client's
acceptance starts. See docs/features/proposals.md.

The public accept calls `start_on_acceptance` and the notify functions inside
its one transaction, so a failure anywhere leaves nothing half made. Raising
the invoice calls `start_requested_project`, so an estimate converted before
the client accepts still starts its project.
"""

from decimal import ROUND_HALF_UP, Decimal

from django.utils import timezone

from common import notifications
from common.models import Profile
from common.modules import module_is_available
from common.permissions import is_org_admin
from invoices.models import Invoice, InvoiceLineItem
from projects.models import Project

CENT = Decimal("0.01")
ESTIMATES_LINK = "/invoices/estimates"


def _cents(value):
    return Decimal(value).quantize(CENT, ROUND_HALF_UP)


def pre_tax_total(estimate):
    """The subtotal less the document discount, each to the cent half up, as
    the clients work it out. `Estimate.recalculate_totals` leaves the discount
    unrounded in memory and the column rounds it on save, so rounding here
    gives the same deposit before and after a reload."""
    return _cents(estimate.subtotal) - _cents(estimate.discount_amount)


def deposit_part(estimate):
    """The deposit before tax: its share of the pre-tax total, to the cent."""
    return _cents(pre_tax_total(estimate) * estimate.deposit_percent / Decimal("100"))


def _deposit_label(estimate):
    percent = format(estimate.deposit_percent.normalize(), "f")
    label = f"Deposit: {percent}% of estimate {estimate.estimate_number}"
    return f"{label}, {estimate.title}" if estimate.title else label


def _deposit_draft(estimate, project=None):
    """The deposit invoice and its one line, unsaved."""
    label = _deposit_label(estimate)
    invoice = Invoice(
        org_id=estimate.org_id,
        invoice_title=label[:100],
        status="Draft",
        account_id=estimate.account_id,
        contact_id=estimate.contact_id,
        opportunity_id=estimate.opportunity_id,
        project=project,
        client_name=estimate.client_name,
        client_email=estimate.client_email,
        client_phone=estimate.client_phone,
        client_address_line=estimate.client_address_line,
        client_city=estimate.client_city,
        client_state=estimate.client_state,
        client_postcode=estimate.client_postcode,
        client_country=estimate.client_country,
        currency=estimate.currency,
        tax_rate=estimate.tax_rate,
        issue_date=timezone.localdate(),
        created_by_id=estimate.created_by_id,
    )
    line = InvoiceLineItem(
        org_id=estimate.org_id,
        name=label[:255],
        description=label[:500],
        quantity=Decimal("1"),
        unit_price=deposit_part(estimate),
        tax_rate=estimate.tax_rate,
        order=0,
    )
    return invoice, line


def estimate_deposit(estimate):
    """``{"percent", "amount", "currency"}``, or None without a deposit.

    ``amount`` is the total the deposit invoice will have: the draft is totalled
    by `Invoice.recalculate_totals`, and rounded as its column stores it. A
    deposit that would total 0.00 is no deposit, so it is None too.
    """
    if estimate.deposit_percent is None:
        return None
    invoice, line = _deposit_draft(estimate)
    invoice.recalculate_totals(lines=[line])
    amount = _cents(invoice.total_amount)
    if not amount:
        return None
    return {
        "percent": str(estimate.deposit_percent.quantize(CENT)),
        "amount": str(amount),
        "currency": estimate.currency,
    }


def estimate_people(estimate):
    """The estimate's active assignees and its creator's active profile in the
    org, each once."""
    people = list(
        estimate.assigned_to.filter(org_id=estimate.org_id, is_active=True)
        .select_related("user")
        .order_by("created_at")
    )
    if estimate.created_by_id:
        creator = (
            Profile.objects.filter(
                org_id=estimate.org_id, user_id=estimate.created_by_id, is_active=True
            )
            .select_related("user")
            .first()
        )
        if creator is not None and creator not in people:
            people.append(creator)
    return people


def _start_project(estimate, people):
    name = estimate.title or (
        f"{estimate.account.name}, estimate {estimate.estimate_number}"
    )
    budget = None
    if estimate.project_billing_type != "non_billable":
        budget = pre_tax_total(estimate)
    project = Project.objects.create(
        org=estimate.org,
        name=name[: Project._meta.get_field("name").max_length],
        account_id=estimate.account_id,
        deal_id=estimate.opportunity_id,
        currency=estimate.currency,
        billing_type=estimate.project_billing_type,
        budget_amount=budget,
        status="active",
        start_date=timezone.localdate(),
        created_by_id=estimate.created_by_id,
    )
    project.assigned_to.set(people)
    return project


def _draft_deposit_invoice(estimate, project):
    invoice, line = _deposit_draft(estimate, project)
    invoice.org = estimate.org
    invoice.save()
    line.invoice = invoice
    line.save()
    invoice.recalculate_totals()
    invoice.save()
    invoice.assigned_to.set(estimate.assigned_to.all())
    invoice.teams.set(estimate.teams.all())
    return invoice


def start_requested_project(estimate):
    """Start the project the estimate asks for, unless it has one, and set
    ``estimate.project``. It asks with ``start_project``, an account and
    Projects on. Returns the project or None; the caller saves the estimate."""
    if (
        estimate.project_id is None
        and estimate.start_project
        and estimate.account_id
        and module_is_available(estimate.org, "projects")
    ):
        estimate.project = _start_project(estimate, estimate_people(estimate))
    return estimate.project


def start_on_acceptance(estimate):
    """Start the project and draft the deposit invoice the estimate asks for,
    and link both to it. The caller saves ``project`` and ``deposit_invoice``.

    Never touches ``converted_to_invoice``: the deposit is not the conversion,
    and raising the full invoice stays available.
    """
    project = start_requested_project(estimate)
    deposit = None
    if estimate_deposit(estimate) is not None:
        deposit = _draft_deposit_invoice(estimate, project)
    estimate.deposit_invoice = deposit


def _recipients(estimate):
    people = estimate_people(estimate)
    if people:
        return people
    admins = Profile.objects.filter(org_id=estimate.org_id, is_active=True)
    return [p for p in admins.select_related("user") if is_org_admin(p)]


def _notify(estimate, verb, link, data):
    for person in _recipients(estimate):
        notifications.create(
            person,
            verb,
            entity=estimate,
            entity_name=estimate.estimate_number,
            link=link,
            data=data,
        )


def notify_accepted(estimate):
    project_id = str(estimate.project_id) if estimate.project_id else None
    deposit_id = (
        str(estimate.deposit_invoice_id) if estimate.deposit_invoice_id else None
    )
    if project_id:
        link = f"/projects/{project_id}"
    elif deposit_id:
        link = f"/invoices/{deposit_id}"
    else:
        link = ESTIMATES_LINK
    _notify(
        estimate,
        "estimate.accepted",
        link,
        {
            "estimate_number": estimate.estimate_number,
            "client_name": estimate.accepted_by_name,
            "project_id": project_id,
            "deposit_invoice_id": deposit_id,
        },
    )


def notify_declined(estimate):
    _notify(
        estimate,
        "estimate.declined",
        ESTIMATES_LINK,
        {
            "estimate_number": estimate.estimate_number,
            "client_name": estimate.client_name,
        },
    )
