"""A project's budget burn, and the notifications at 80% and 100% of a budget.

Burn counts every stopped entry on the project, whoever logged it. Money is
summed only in the project's currency, so two currencies are never added.
"""

from decimal import Decimal

from django.db.models import Count, F, Q, Sum

from cases.models import TimeEntry
from cases.time_reports import _VALUE, hours, money
from common import notifications
from common.models import Profile
from common.modules import module_is_available
from common.permissions import is_org_admin
from invoices.models import Invoice
from projects.models import Project

LEVELS = (100, 80)

_RATED = Q(billable=True, hourly_rate__isnull=False, currency=F("project__currency"))


def _percent(used, budget):
    if budget is None or budget <= 0:
        return None
    return int(Decimal(used) * 100 / budget)


def burn_for(projects, viewer=None):
    """``{project id: burn}`` for ``projects``, in two queries at most.

    ``invoiced_amount`` is the invoices' total only for ``viewer`` an org admin
    while Invoices is on; it is ``None`` otherwise, and without a viewer.
    """
    projects = list(projects)
    ids = [p.pk for p in projects]
    orgs = {p.org_id for p in projects}
    time = {
        row["project_id"]: row
        for row in TimeEntry.objects.filter(
            org_id__in=orgs, project_id__in=ids, ended_at__isnull=False
        )
        .values("project_id")
        .annotate(
            logged_minutes=Sum("duration_minutes"),
            billable_minutes=Sum("duration_minutes", filter=Q(billable=True)),
            value_sum=Sum(_VALUE, filter=_RATED),
            unbilled_sum=Sum(_VALUE, filter=_RATED & Q(invoice__isnull=True)),
        )
        .order_by()
    }
    show_invoiced = (
        viewer is not None
        and is_org_admin(viewer)
        and module_is_available(viewer.org, "invoices")
    )
    invoiced = {}
    if show_invoiced:
        invoiced = {
            row["project_id"]: row["total"]
            for row in Invoice.objects.filter(
                org_id__in=orgs, project_id__in=ids, currency=F("project__currency")
            )
            .exclude(status="Cancelled")
            .values("project_id")
            .annotate(total=Sum("total_amount"))
            .order_by()
        }
    result = {}
    for project in projects:
        row = time.get(project.pk, {})
        logged = row.get("logged_minutes") or 0
        value = row.get("value_sum") or Decimal("0")
        result[project.pk] = {
            "logged_hours": hours(logged),
            "billable_hours": hours(row.get("billable_minutes") or 0),
            "billable_value": money(value),
            "unbilled_value": money(row.get("unbilled_sum")),
            "invoiced_amount": (
                money(invoiced.get(project.pk)) if show_invoiced else None
            ),
            "hours_percent": _percent(Decimal(logged) / 60, project.budget_hours),
            "amount_percent": _percent(value, project.budget_amount),
        }
    return result


def unbilled_entries(project, up_to):
    """The entries billing ``project`` up to ``up_to`` would take, unlocked."""
    return TimeEntry.objects.filter(
        org_id=project.org_id,
        project=project,
        ended_at__isnull=False,
        billable=True,
        invoice__isnull=True,
        started_at__date__lte=up_to,
    )


def unbilled_summary(project, up_to):
    row = unbilled_entries(project, up_to).aggregate(
        entry_count=Count("id"),
        minutes_sum=Sum("duration_minutes"),
        value_sum=Sum(_VALUE, filter=_RATED),
        unrated_count=Count("id", filter=Q(hourly_rate__isnull=True)),
    )
    return {
        "entry_count": row["entry_count"],
        "hours": hours(row["minutes_sum"]),
        "value": money(row["value_sum"]),
        "currency": project.currency,
        "unrated_count": row["unrated_count"],
    }


def _recipients(project):
    assigned = set(project.assigned_to.values_list("id", flat=True))
    people = Profile.objects.filter(org_id=project.org_id, is_active=True)
    return [
        p for p in people.select_related("user") if p.id in assigned or is_org_admin(p)
    ]


def check_budget_alerts(project):
    """Notify the project's people and the org's admins the first time a budget
    reaches 80% and 100%. The conditional UPDATE is the once-only guard, so two
    saves racing past a level send one notification, not two."""
    if not module_is_available(project.org, "projects"):
        return
    burn = burn_for([project])[project.pk]
    for kind, field in (("hours", "hours_alert"), ("amount", "amount_alert")):
        percent = burn[f"{kind}_percent"]
        if percent is None:
            continue
        level = next((lvl for lvl in LEVELS if percent >= lvl), None)
        if level is None:
            continue
        won = Project.objects.filter(pk=project.pk, **{f"{field}__lt": level}).update(
            **{field: level}
        )
        if not won:
            continue
        setattr(project, field, level)
        for person in _recipients(project):
            notifications.create(
                person,
                "project.budget",
                entity=project,
                link=f"/projects/{project.pk}",
                data={"kind": kind, "percent": level, "project": project.name},
            )
