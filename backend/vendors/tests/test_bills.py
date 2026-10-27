from decimal import Decimal

import pytest

from common.testing import set_modules_off
from vendors.models import Bill, Vendor

pytestmark = pytest.mark.django_db
URL = "/api/vendors/bills/"


@pytest.fixture
def vendor(org_a):
    return Vendor.objects.create(org=org_a, name="Hosting")


def bill_body(vendor, **extra):
    return {
        "vendor": str(vendor.pk),
        "bill_number": "INV-1",
        "bill_date": "2026-10-31",
        "due_date": "2026-11-30",
        "total_amount": "100.00",
        **extra,
    }


def test_crud_and_balance(admin_client, vendor, org_b, admin_user):
    response = admin_client.post(
        URL, bill_body(vendor, org=str(org_b.pk)), format="json"
    )
    assert response.status_code == 201, response.data
    data = response.json()
    assert data["balance_due"] == "100.00"
    assert data["status"] == Bill.STATUS_UNPAID
    assert data["vendor_name"] == "Hosting"
    bill = Bill.objects.get(pk=data["id"])
    assert bill.org == vendor.org
    assert bill.created_by == admin_user

    detail = f"{URL}{bill.pk}/"
    data = admin_client.patch(detail, {"amount_paid": "40"}, format="json").json()
    assert data["balance_due"] == "60.00"
    assert data["status"] == Bill.STATUS_PARTIALLY_PAID
    data = admin_client.patch(detail, {"amount_paid": "100"}, format="json").json()
    assert data["status"] == Bill.STATUS_PAID
    data = admin_client.patch(detail, {"status": "VOID"}, format="json").json()
    assert data["status"] == Bill.STATUS_VOID
    data = admin_client.patch(detail, {"status": "UNPAID"}, format="json").json()
    assert data["status"] == Bill.STATUS_PAID  # follows the amounts again

    assert admin_client.get(URL, {"vendor": str(vendor.pk)}).json()["count"] == 1
    assert admin_client.get(URL, {"vendor": "nope"}).status_code == 400
    assert admin_client.delete(detail).status_code == 204
    assert not Bill.objects.exists()


def test_validation(admin_client, vendor):
    bad = [
        {"amount_paid": "150"},
        {"total_amount": "-1"},
        {"due_date": "2026-10-01"},
    ]
    for extra in bad:
        response = admin_client.post(URL, bill_body(vendor, **extra), format="json")
        assert response.status_code == 400, extra


def test_overdue_filter(admin_client, vendor, org_a):
    Bill.objects.create(
        org=org_a,
        vendor=vendor,
        bill_date="2020-01-01",
        due_date="2020-02-01",
        total_amount=Decimal("10"),
    )
    Bill.objects.create(
        org=org_a,
        vendor=vendor,
        bill_date="2020-01-01",
        due_date="2020-02-01",
        total_amount=Decimal("10"),
        amount_paid=Decimal("10"),
    )
    rows = admin_client.get(URL, {"overdue": "true"}).json()["results"]
    assert len(rows) == 1
    assert rows[0]["is_overdue"] is True


def test_vendor_with_bills_cannot_be_deleted(admin_client, vendor, org_a):
    Bill.objects.create(org=org_a, vendor=vendor, bill_date="2026-10-31")
    response = admin_client.delete(f"/api/vendors/{vendor.pk}/")
    assert response.status_code == 400
    assert Vendor.objects.filter(pk=vendor.pk).exists()


def test_vendor_delete_names_bills_when_bills_are_off(admin_client, vendor, org_a):
    Bill.objects.create(org=org_a, vendor=vendor, bill_date="2026-10-31")
    set_modules_off(org_a, "bills")
    response = admin_client.delete(f"/api/vendors/{vendor.pk}/")
    assert response.status_code == 409
    assert response.json()["module"] == "bills"
    assert Vendor.objects.filter(pk=vendor.pk).exists()


def test_vendor_without_bills_deletes_with_bills_off(admin_client, vendor, org_a):
    set_modules_off(org_a, "bills")
    response = admin_client.delete(f"/api/vendors/{vendor.pk}/")
    assert response.status_code == 204


def test_cross_org_and_hidden_vendor(org_b_client, user_client, vendor, org_a):
    bill = Bill.objects.create(org=org_a, vendor=vendor, bill_date="2026-10-31")
    assert org_b_client.get(f"{URL}{bill.pk}/").status_code == 404
    assert org_b_client.get(URL).json()["count"] == 0
    # A member who cannot see the vendor cannot see or create its bills.
    assert user_client.get(f"{URL}{bill.pk}/").status_code == 404
    assert user_client.post(URL, bill_body(vendor), format="json").status_code == 400
