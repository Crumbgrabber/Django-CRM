import pytest
from rest_framework.test import APIClient

from common.testing import rls_org
from vendors.access import has_vendor_access, may_delete_vendor
from vendors.models import Vendor

pytestmark = pytest.mark.django_db
URL = "/api/vendors/"


def test_create_with_empty_relationships(admin_client):
    relationships = {name: [] for name in ("assigned_to", "teams", "contacts", "tags")}
    response = admin_client.post(
        URL, {"name": "Unassigned", **relationships}, format="json"
    )
    assert response.status_code == 201, response.data
    vendor = Vendor.objects.get(pk=response.json()["id"])
    for name in relationships:
        assert response.json()[name] == []
        assert not getattr(vendor, name).exists()


def test_crud(admin_client, org_a, org_b, admin_user):
    response = admin_client.post(
        URL,
        {"name": "Hosting", "org": str(org_b.pk), "created_by": None},
        format="json",
    )
    assert response.status_code == 201
    vendor = Vendor.objects.get(pk=response.json()["id"])
    assert vendor.org == org_a
    assert vendor.created_by == admin_user
    detail = f"{URL}{vendor.pk}/"
    assert admin_client.get(detail).status_code == 200
    assert admin_client.put(detail, {"name": "Cloud"}, format="json").status_code == 200
    assert (
        admin_client.patch(
            detail, {"phone": "+1 (555) 123-4567"}, format="json"
        ).status_code
        == 200
    )
    assert admin_client.get(URL, {"search": "cloud"}).json()["count"] == 1
    assert admin_client.get(URL, {"search": "missing"}).json()["count"] == 0
    assert admin_client.delete(detail).status_code == 204
    assert admin_client.get(detail).status_code == 404


def test_duplicate_names(admin_client, org_a, org_b):
    Vendor.objects.create(org=org_a, name="Hosting")
    assert admin_client.post(URL, {"name": "HOSTING"}, format="json").status_code == 400
    second = Vendor.objects.create(org=org_a, name="Other")
    assert (
        admin_client.patch(
            f"{URL}{second.pk}/", {"name": "hosting"}, format="json"
        ).status_code
        == 400
    )
    with rls_org(org_b):
        Vendor.objects.create(org=org_b, name="Hosting")


@pytest.mark.parametrize("method", ["get", "put", "patch", "delete"])
def test_cross_org_is_404(org_b_client, org_a, method):
    vendor = Vendor.objects.create(org=org_a, name="Private")
    response = getattr(org_b_client, method)(f"{URL}{vendor.pk}/")
    assert response.status_code == 404
    assert org_b_client.get(URL).json()["count"] == 0


@pytest.mark.parametrize("method", ["get", "put", "patch", "delete"])
def test_malformed_id(admin_client, method):
    assert getattr(admin_client, method)(f"{URL}not-a-uuid/").status_code == 404


def test_access_rules(user_client, user_profile, admin_profile, org_a, regular_user):
    vendor = Vendor.objects.create(
        org=org_a, name="Private", created_by=admin_profile.user
    )
    detail = f"{URL}{vendor.pk}/"
    assert not has_vendor_access(user_profile, vendor)
    assert not may_delete_vendor(user_profile, vendor)
    assert has_vendor_access(admin_profile, vendor)
    assert may_delete_vendor(admin_profile, vendor)
    assert user_client.get(URL).json()["count"] == 0
    assert user_client.get(detail).status_code == 404
    assert (
        user_client.patch(detail, {"name": "Hidden"}, format="json").status_code == 404
    )
    vendor.assigned_to.add(user_profile)
    assert has_vendor_access(user_profile, vendor)
    assert user_client.get(URL).json()["count"] == 1
    assert user_client.get(detail).status_code == 200
    assert (
        user_client.patch(detail, {"city": "Boston"}, format="json").status_code == 200
    )
    assert user_client.delete(detail).status_code == 403
    vendor.assigned_to.clear()
    vendor.created_by = regular_user
    vendor.save()
    assert has_vendor_access(user_profile, vendor)
    assert may_delete_vendor(user_profile, vendor)
    assert user_client.get(detail).status_code == 200
    assert user_client.delete(detail).status_code == 204


def test_member_create_and_pagination(user_client, org_a):
    for i in range(3):
        assert (
            user_client.post(URL, {"name": f"Vendor {i}"}, format="json").status_code
            == 201
        )
    response = user_client.get(URL, {"limit": 1, "offset": 1}).json()
    assert response["count"] == 3
    assert len(response["results"]) == 1
    assert response["next"] and response["previous"]


def test_invalid_fields_and_foreign_relations(admin_client, profile_b):
    for body in [
        {"phone": "letters"},
        {"currency": "XXX"},
        {"website": "javascript:alert(1)"},
        {"email": "invalid"},
        {"assigned_to": [str(profile_b.pk)]},
    ]:
        response = admin_client.post(URL, {"name": "Invalid", **body}, format="json")
        assert response.status_code == 400, response.data
    assert not Vendor.objects.exists()


def test_requires_authentication():
    assert APIClient().get(URL).status_code in (401, 403)


@pytest.mark.parametrize("field", ["assigned_to", "teams", "contacts", "tags"])
def test_relationships_are_org_scoped(
    admin_client, org_a, org_b, admin_profile, profile_b, field
):
    from common.models import Tags, Teams
    from contacts.models import Contact

    def related(org, profile):
        if field == "assigned_to":
            return profile
        if field == "teams":
            return Teams.objects.create(org=org, name="Team")
        if field == "tags":
            return Tags.objects.create(org=org, name="Tag")
        return Contact.objects.create(org=org, first_name="Ada", last_name="Lovelace")

    mine = related(org_a, admin_profile)
    with rls_org(org_b):
        theirs = related(org_b, profile_b)
    response = admin_client.post(
        URL, {"name": "Good", field: [str(mine.pk)]}, format="json"
    )
    assert response.status_code == 201
    detail = f"{URL}{response.json()['id']}/"
    response = admin_client.patch(detail, {field: [str(theirs.pk)]}, format="json")
    assert response.status_code == 400, response.data
    assert admin_client.get(detail).json()[field] == [str(mine.pk)]
    response = admin_client.patch(detail, {field: []}, format="json")
    assert response.status_code == 200, response.data
    assert response.json()[field] == []
    vendor = Vendor.objects.get(pk=response.json()["id"])
    assert not getattr(vendor, field).exists()
