"""An org admin creates users with a password and edits their account fields,
but only for members of this org alone."""

import pytest
from rest_framework_simplejwt.token_blacklist.models import (
    BlacklistedToken,
    OutstandingToken,
)
from rest_framework_simplejwt.tokens import RefreshToken

from common.models import Profile, User

USERS = "/api/users/"


def _detail(user):
    return f"/api/user/{user.id}/"


@pytest.fixture
def member(db, org_a):
    user = User.objects.create_user(
        email="member@test.com", password="old-pass-123", name="Old Name"
    )
    Profile.objects.create(user=user, org=org_a, role="USER", is_active=True)
    return user


def test_admin_creates_user_with_password_and_role(admin_client, org_a):
    resp = admin_client.post(
        USERS,
        {
            "email": "New@Test.com",
            "name": "Nia New",
            "password": "Str0ng-pass-77",
            "role": "ADMIN",
        },
        format="json",
    )
    assert resp.status_code == 201
    user = User.objects.get(email="new@test.com")
    assert user.name == "Nia New"
    assert user.check_password("Str0ng-pass-77")
    assert Profile.objects.get(user=user, org=org_a).role == "ADMIN"


def test_create_without_password_leaves_it_unusable(admin_client):
    resp = admin_client.post(
        USERS, {"email": "inv@test.com", "role": "USER"}, format="json"
    )
    assert resp.status_code == 201
    assert not User.objects.get(email="inv@test.com").has_usable_password()


def test_create_rejects_a_weak_password(admin_client):
    resp = admin_client.post(
        USERS,
        {"email": "weak@test.com", "password": "123", "role": "USER"},
        format="json",
    )
    assert resp.status_code == 400
    assert not User.objects.filter(email="weak@test.com").exists()


def test_password_for_an_account_that_exists_elsewhere_is_refused(
    admin_client, user_b, profile_b
):
    resp = admin_client.post(
        USERS,
        {"email": user_b.email, "password": "Str0ng-pass-77", "role": "USER"},
        format="json",
    )
    assert resp.status_code == 400
    user_b.refresh_from_db()
    assert user_b.check_password("testpass123")


def test_member_cannot_create_users(user_client):
    resp = user_client.post(
        USERS,
        {"email": "x@test.com", "password": "Str0ng-pass-77", "role": "USER"},
        format="json",
    )
    assert resp.status_code == 403
    assert not User.objects.filter(email="x@test.com").exists()


def test_admin_edits_email_name_and_password(admin_client, member):
    resp = admin_client.patch(
        _detail(member),
        {
            "email": "Renamed@Test.com",
            "name": "New Name",
            "password": "Str0ng-pass-77",
        },
        format="json",
    )
    assert resp.status_code == 200
    member.refresh_from_db()
    assert member.email == "renamed@test.com"
    assert member.name == "New Name"
    assert member.check_password("Str0ng-pass-77")


def test_password_change_revokes_refresh_tokens(admin_client, member):
    token = RefreshToken.for_user(member)
    admin_client.patch(_detail(member), {"password": "Str0ng-pass-77"}, format="json")
    outstanding = OutstandingToken.objects.get(jti=token["jti"])
    assert BlacklistedToken.objects.filter(token=outstanding).exists()


def test_a_change_to_other_fields_keeps_refresh_tokens(admin_client, member):
    token = RefreshToken.for_user(member)
    admin_client.patch(_detail(member), {"name": "Only Name"}, format="json")
    outstanding = OutstandingToken.objects.get(jti=token["jti"])
    assert not BlacklistedToken.objects.filter(token=outstanding).exists()


def test_email_taken_by_another_account_is_refused(admin_client, member, user_b):
    resp = admin_client.patch(_detail(member), {"email": user_b.email}, format="json")
    assert resp.status_code == 400
    member.refresh_from_db()
    assert member.email == "member@test.com"


def test_multi_org_member_account_fields_stay_read_only(admin_client, member, org_b):
    Profile.objects.create(user=member, org=org_b, role="USER", is_active=True)
    for body in (
        {"email": "hijack@test.com"},
        {"password": "Str0ng-pass-77"},
        {"name": "Hijacked"},
    ):
        assert (
            admin_client.patch(_detail(member), body, format="json").status_code == 400
        )
    member.refresh_from_db()
    assert member.email == "member@test.com"
    assert member.check_password("old-pass-123")
    assert member.name == "Old Name"
    # Org-level fields are still the admin's to change.
    assert (
        admin_client.patch(
            _detail(member), {"role": "ADMIN"}, format="json"
        ).status_code
        == 200
    )


def test_superuser_account_fields_stay_read_only(admin_client, member):
    member.is_superuser = True
    member.save()
    resp = admin_client.patch(
        _detail(member), {"password": "Str0ng-pass-77"}, format="json"
    )
    assert resp.status_code == 400
    member.refresh_from_db()
    assert member.check_password("old-pass-123")


def test_admin_cannot_change_their_own_password_or_email_here(admin_client, admin_user):
    for body in ({"password": "Str0ng-pass-77"}, {"email": "me2@test.com"}):
        assert (
            admin_client.patch(_detail(admin_user), body, format="json").status_code
            == 400
        )
    admin_user.refresh_from_db()
    assert admin_user.check_password("testpass123")


def test_member_cannot_edit_anothers_account(user_client, admin_user, admin_profile):
    resp = user_client.patch(
        _detail(admin_user), {"password": "Str0ng-pass-77"}, format="json"
    )
    assert resp.status_code == 403
    admin_user.refresh_from_db()
    assert admin_user.check_password("testpass123")


def test_member_cannot_set_their_own_password_here(user_client, regular_user):
    resp = user_client.patch(
        _detail(regular_user), {"password": "Str0ng-pass-77"}, format="json"
    )
    assert resp.status_code == 400
    regular_user.refresh_from_db()
    assert regular_user.check_password("testpass123")


def test_other_orgs_admin_cannot_reach_the_member(org_b_client, member):
    resp = org_b_client.patch(
        _detail(member), {"password": "Str0ng-pass-77"}, format="json"
    )
    assert resp.status_code == 404
    member.refresh_from_db()
    assert member.check_password("old-pass-123")
