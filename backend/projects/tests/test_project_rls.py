"""Row-level security on the two project tables (PostgreSQL only)."""

from decimal import Decimal

import pytest
from django.db import DatabaseError, connection, transaction

from accounts.models import Account
from common.testing import rls_policy_gaps
from conftest import rls_org
from projects.models import Project, ProjectRate


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
