"""The anonymous accept starts its project and deposit invoice under row-level
security, in the token's org and no other (PostgreSQL only)."""

from decimal import Decimal

import pytest
from django.db import connection
from rest_framework.test import APIClient

from accounts.models import Account
from common.models import Notification
from conftest import clear_rls_context, rls_org
from invoices.models import Estimate, EstimateLineItem, Invoice
from projects.models import Project

pytestmark = pytest.mark.postgres_only


def _need_rls():
    if connection.vendor != "postgresql":
        pytest.skip("Row-level security is a PostgreSQL feature")
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user"
        )
        if cursor.fetchone()[0]:
            pytest.skip("Needs a role row-level security binds, as in CI")


def _proposal(org, admin_user):
    account = Account.objects.create(name=f"Client of {org.name}", org=org)
    estimate = Estimate.objects.create(
        org=org,
        account=account,
        title="Proposal",
        currency="USD",
        start_project=True,
        deposit_percent=Decimal("50"),
        created_by=admin_user,
    )
    EstimateLineItem.objects.create(
        estimate=estimate, org=org, description="Work", unit_price=Decimal("200")
    )
    estimate.save()
    Estimate.objects.filter(pk=estimate.pk).update(status="Sent")
    return estimate


def test_the_accept_makes_its_records_in_the_tokens_org_only(
    org_a, org_b, admin_profile, admin_user, profile_b
):
    _need_rls()
    estimate = _proposal(org_a, admin_user)
    with rls_org(org_b):
        _proposal(org_b, profile_b.user)

    clear_rls_context()
    res = APIClient().post(
        f"/api/public/estimate/{estimate.public_token}/accept/",
        {"name": "Nora", "email": "nora@client.example", "org": str(org_b.id)},
        format="json",
    )
    assert res.status_code == 200

    with rls_org(org_a):
        estimate = Estimate.objects.get(pk=estimate.pk)
        assert estimate.status == "Accepted"
        project = Project.objects.get()
        invoice = Invoice.objects.get()
        assert (estimate.project_id, estimate.deposit_invoice_id) == (
            project.pk,
            invoice.pk,
        )
        assert project.org_id == invoice.org_id == org_a.id
        assert invoice.line_items.get().org_id == org_a.id
        assert Notification.objects.get().recipient == admin_profile

    with rls_org(org_b):
        assert not Project.objects.exists()
        assert not Invoice.objects.exists()
        assert not Notification.objects.exists()
        assert Estimate.objects.get().status == "Sent"
