"""Row-level security on the two project tables, and the retainer job under
it (PostgreSQL only)."""

from decimal import Decimal
from unittest import mock

import pytest
from django.db import DatabaseError, connection, transaction
from django.utils import timezone

from accounts.models import Account
from common.testing import rls_policy_gaps
from conftest import clear_rls_context, rls_org
from invoices.models import Invoice
from projects.models import Project, ProjectRate
from projects.retainers import add_months, month_of
from projects.tasks import draft_retainer_invoices
from projects.tests.conftest import make_retainer


def _need_rls():
    if connection.vendor != "postgresql":
        pytest.skip("Row-level security is a PostgreSQL feature")
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user"
        )
        if cursor.fetchone()[0]:
            pytest.skip("Needs a role row-level security binds, as in CI")


@pytest.mark.postgres_only
def test_both_tables_have_their_policies():
    if connection.vendor != "postgresql":
        pytest.skip("RLS policies exist only on PostgreSQL")
    assert rls_policy_gaps(["project", "project_rate"]) == []


@pytest.mark.postgres_only
def test_another_orgs_projects_and_rates_are_invisible(org_a, org_b, admin_profile):
    _need_rls()
    mine = Project.objects.create(
        org=org_a, name="Mine", account=Account.objects.create(name="A", org=org_a)
    )
    ProjectRate.objects.create(
        org=org_a, project=mine, profile=admin_profile, hourly_rate=Decimal("10")
    )
    with rls_org(org_b):
        theirs = Project.objects.create(
            org=org_b,
            name="Theirs",
            account=Account.objects.create(name="B", org=org_b),
        )
        assert list(Project.objects.all()) == [theirs]
        assert not ProjectRate.objects.exists()

    assert list(Project.objects.all()) == [mine]
    assert ProjectRate.objects.count() == 1


@pytest.mark.postgres_only
def test_a_project_cannot_be_written_into_another_org(org_a, org_b):
    _need_rls()
    with rls_org(org_b):
        account = Account.objects.create(name="B", org=org_b)
    with pytest.raises(DatabaseError), transaction.atomic():
        Project.objects.create(org=org_b, name="Planted", account=account)


def _current_org():
    with connection.cursor() as cursor:
        cursor.execute("SELECT current_setting('app.current_org', true)")
        return cursor.fetchone()[0] or ""


@pytest.mark.postgres_only
def test_the_retainer_job_drafts_each_orgs_months_under_its_own_context(org_a, org_b):
    _need_rls()
    last_month = add_months(month_of(timezone.localdate()), -1)
    projects = {}
    for org in (org_a, org_b):
        with rls_org(org):
            account = Account.objects.create(name=f"Client {org.name}", org=org)
            projects[org.id] = make_retainer(
                org, account, retainer_next_month=last_month
            )
    seen = []
    save = Invoice.save

    def spy(self, *args, **kwargs):
        seen.append((str(self.org_id), _current_org()))
        return save(self, *args, **kwargs)

    clear_rls_context()
    with mock.patch.object(Invoice, "save", spy):
        draft_retainer_invoices()
    assert _current_org() == "", "the job left an org's context on the connection"

    assert {org for org, _ in seen} == {str(org_a.id), str(org_b.id)}
    assert all(org == context for org, context in seen)
    for org in (org_a, org_b):
        with rls_org(org):
            drafted = list(Invoice.objects.values_list("project_id", flat=True))
            assert drafted == [projects[org.id].id]
