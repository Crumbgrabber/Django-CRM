import pytest
from django.db import DatabaseError, connection, transaction

from common.testing import rls_org, rls_policy_gaps
from vendors.models import Vendor

pytestmark = [pytest.mark.django_db, pytest.mark.postgres_only]


def test_vendor_policies():
    if connection.vendor != "postgresql":
        pytest.skip("RLS requires PostgreSQL")
    assert rls_policy_gaps(["vendors"]) == []


def test_vendor_rls_isolation(org_a, org_b):
    if connection.vendor != "postgresql":
        pytest.skip("RLS requires PostgreSQL")
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user"
        )
        if cursor.fetchone()[0]:
            pytest.skip("Requires a role bound by RLS")
    mine = Vendor.objects.create(org=org_a, name="Mine")
    with rls_org(org_b):
        theirs = Vendor.objects.create(org=org_b, name="Theirs")
        assert list(Vendor.objects.all()) == [theirs]
    assert list(Vendor.objects.all()) == [mine]
    with pytest.raises(DatabaseError), transaction.atomic():
        Vendor.objects.create(org=org_b, name="Forbidden")


def test_bill_policies():
    if connection.vendor != "postgresql":
        pytest.skip("RLS requires PostgreSQL")
    assert rls_policy_gaps(["vendor_bills"]) == []
