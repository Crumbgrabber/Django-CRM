"""Email + password sign-in: success, wrong password, unknown email, disabled
account, org binding and the per-email lockout."""

import pytest
from django.core.cache import cache
from rest_framework.test import APIClient

from common.models import Org, Profile, User
from common.throttles import (
    FirstRefusalThrottleMixin,
    MagicLinkIPThrottle,
    PasswordLoginGlobalThrottle,
    PasswordLoginIPThrottle,
)
from common.views.auth_views import PasswordLoginView

LOGIN = "/api/auth/login/"


@pytest.fixture(autouse=True)
def _clear_cache():
    cache.clear()
    yield
    cache.clear()


@pytest.fixture
def user(db):
    return User.objects.create_user(email="new@example.com", password="correct-horse-9")


def _post(email, password):
    return APIClient().post(
        LOGIN, {"email": email, "password": password}, format="json"
    )


def test_success_returns_tokens_and_orgs(user):
    org = Org.objects.create(name="Acme")
    Profile.objects.create(user=user, org=org, role="ADMIN", is_active=True)
    resp = _post("New@Example.com", "correct-horse-9")
    assert resp.status_code == 200
    assert resp.data["access_token"] and resp.data["refresh_token"]
    assert [o["id"] for o in resp.data["organizations"]] == [str(org.id)]
    assert resp.data["current_org"]["id"] == str(org.id)


def test_two_orgs_binds_none(user):
    for name in ("A", "B"):
        Profile.objects.create(
            user=user, org=Org.objects.create(name=name), role="ADMIN", is_active=True
        )
    resp = _post("new@example.com", "correct-horse-9")
    assert resp.status_code == 200
    assert len(resp.data["organizations"]) == 2
    assert "current_org" not in resp.data


def test_wrong_password_refused(user):
    resp = _post("new@example.com", "nope")
    assert resp.status_code == 400
    assert "access_token" not in resp.data


def test_unknown_email_same_answer_as_wrong_password(user):
    wrong = _post("new@example.com", "nope")
    unknown = _post("ghost@example.com", "nope")
    assert unknown.status_code == wrong.status_code == 400
    assert unknown.data == wrong.data


def test_invited_user_without_password_cannot_sign_in(db):
    User.objects.create_user(email="invited@example.com", password=None)
    assert _post("invited@example.com", "").status_code == 400


def test_disabled_account_refused(user):
    user.is_active = False
    user.save()
    resp = _post("new@example.com", "correct-horse-9")
    assert resp.status_code != 200
    assert "access_token" not in resp.data


def test_locks_after_repeated_failures(user):
    for _ in range(10):
        _post("new@example.com", "nope")
    assert _post("new@example.com", "correct-horse-9").status_code == 400


def _post_from(ip, email="new@example.com", password="nope"):
    return APIClient().post(
        LOGIN, {"email": email, "password": password}, format="json", REMOTE_ADDR=ip
    )


def test_wiring_uses_own_throttle_scope():
    assert PasswordLoginView.throttle_classes == [
        PasswordLoginIPThrottle,
        PasswordLoginGlobalThrottle,
    ]
    assert issubclass(PasswordLoginView, FirstRefusalThrottleMixin)


def test_ip_throttle_refuses_a_flooding_client(user, monkeypatch):
    monkeypatch.setattr(
        PasswordLoginIPThrottle, "THROTTLE_RATES", {"password_login_ip": "2/hour"}
    )
    codes = [
        _post_from("198.51.100.1", f"x{n}@example.com").status_code for n in range(3)
    ]
    assert codes == [400, 400, 429]
    assert _post_from("198.51.100.2").status_code == 400


def test_global_cap_holds_across_clients(user, monkeypatch):
    monkeypatch.setattr(
        PasswordLoginGlobalThrottle,
        "THROTTLE_RATES",
        {"password_login_global": "2/hour"},
    )
    codes = [_post_from(f"198.51.100.{n + 1}").status_code for n in range(3)]
    assert codes == [400, 400, 429]


def test_magic_link_bucket_is_not_shared(user, monkeypatch):
    monkeypatch.setattr(
        MagicLinkIPThrottle, "THROTTLE_RATES", {"magic_link_ip": "1/hour"}
    )
    for _ in range(3):
        assert _post_from("198.51.100.1").status_code == 400
