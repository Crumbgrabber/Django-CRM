"""The hourly job that drafts each retainer's invoice once its month ends."""

import logging

from celery import shared_task
from django.db.models import F, Q
from django.utils import timezone

from common import notifications
from common.models import Org, Profile
from common.modules import module_is_available, module_on_since
from common.org_time import activate_org_timezone
from common.permissions import is_org_admin
from common.tasks import clear_rls_context, set_rls_context
from projects.models import Project
from projects.retainers import RETAINER, bill_month, month_key, month_of

logger = logging.getLogger(__name__)

MODULES = ("projects", "invoices")


def retainer_candidates(org, today):
    """Retainers with an ended month to bill on ``today``, the org's day."""
    return Project.objects.filter(
        org=org,
        billing_type=RETAINER,
        retainer_next_month__lt=month_of(today),
    ).filter(
        Q(retainer_last_month__isnull=True, status="active")
        | Q(
            retainer_last_month__isnull=False,
            retainer_next_month__lte=F("retainer_last_month"),
        )
    )


def _back_on(org):
    """The day the later of the two modules came back on, the org's, or None."""
    stamps = [module_on_since(org, key) for key in MODULES]
    days = [timezone.localdate(when) for when in stamps if when is not None]
    return max(days) if days else None


def _next_month(pk, org):
    return (
        Project.objects.filter(pk=pk, org=org)
        .values_list("retainer_next_month", flat=True)
        .first()
    )


def _notify_admins(org, invoice):
    project = invoice.project
    admins = Profile.objects.filter(org=org, is_active=True).select_related("user")
    for person in admins:
        if not is_org_admin(person):
            continue
        notifications.create(
            person,
            "project.retainer_invoice",
            entity=project,
            link=f"/invoices/{invoice.pk}",
            data={
                "project": project.name,
                "month": month_key(invoice.retainer_month),
                "invoice_number": invoice.invoice_number,
            },
        )


def _bill_ended_months(pk, org, today, skip_before):
    # A skipped month answers None as the open month does, so carry on while
    # the month moves; it stops at the open month or a retainer's end.
    while True:
        month = _next_month(pk, org)
        invoice = bill_month(pk, org, today, skip_before=skip_before)
        if invoice is not None:
            _notify_admins(org, invoice)
        elif _next_month(pk, org) == month:
            return


@shared_task
def draft_retainer_invoices():
    """Draft every ended retainer month, oldest first, in each org with
    Projects and Invoices on. Hourly, so each org's month closes within an
    hour of its own midnight."""
    try:
        for org in Org.objects.all():
            if not all(module_is_available(org, key) for key in MODULES):
                continue
            set_rls_context(org.id)
            activate_org_timezone(org)
            today = timezone.localdate()
            skip_before = _back_on(org)
            due = retainer_candidates(org, today)
            for pk in due.values_list("pk", flat=True):
                try:
                    _bill_ended_months(pk, org, today, skip_before)
                except Exception:
                    logger.exception("Retainer invoice failed for project %s", pk)
    finally:
        timezone.deactivate()
        clear_rls_context()
