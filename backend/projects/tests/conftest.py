import datetime
from decimal import Decimal
from unittest.mock import patch
from zoneinfo import ZoneInfo

import pytest
from django.utils import timezone

from accounts.models import Account
from cases.models import TimeEntry
from common.models import Profile, User
from common.testing import _make_authenticated_client
from projects.models import Project


@pytest.fixture
def account(org_a, admin_user):
    return Account.objects.create(name="Reyes & Co", org=org_a, created_by=admin_user)


@pytest.fixture
def member_account(org_a, regular_user):
    """An account the plain member created, so they may open it."""
    return Account.objects.create(name="Member Co", org=org_a, created_by=regular_user)


@pytest.fixture
def other_member(org_a):
    user = User.objects.create_user(email="other@test.com", password="pw-not-used")
    return Profile.objects.create(user=user, org=org_a, role="USER", is_active=True)


@pytest.fixture
def other_member_client(other_member):
    return _make_authenticated_client(other_member.user, other_member.org, other_member)


def make_project(org, account, created_by=None, assigned=(), **fields):
    project = Project.objects.create(
        org=org,
        account=account,
        created_by=created_by,
        **{"name": "Site build", **fields},
    )
    if assigned:
        project.assigned_to.set(assigned)
    return project


def log_time(project, profile, minutes, *, billable=True, rate="100", days_ago=0, **kw):
    end = timezone.now() - datetime.timedelta(days=days_ago)
    return TimeEntry.objects.create(
        org=project.org,
        project=project,
        profile=profile,
        started_at=end - datetime.timedelta(minutes=minutes),
        ended_at=end,
        billable=billable,
        hourly_rate=Decimal(rate) if rate is not None else None,
        currency=project.currency,
        description=kw.pop("description", "Work"),
        **kw,
    )


class Clock:
    def __init__(self):
        self.now = datetime.datetime(2026, 10, 14, 12, 0, tzinfo=datetime.UTC)

    def set(self, *parts, tz="UTC"):
        self.now = datetime.datetime(*parts, tzinfo=ZoneInfo(tz))


@pytest.fixture
def clock():
    """``timezone.now()`` under the test's control, 14 October 2026 at noon UTC
    until moved."""
    c = Clock()
    with patch("django.utils.timezone.now", side_effect=lambda: c.now):
        yield c


def make_retainer(org, account, **fields):
    """A retainer as the month rules leave one, billing October 2026 next."""
    return make_project(
        org,
        account,
        **{
            "billing_type": "retainer",
            "retainer_fee": Decimal("1000"),
            "retainer_next_month": datetime.date(2026, 10, 1),
            **fields,
        },
    )


def log_at(project, profile, started_at, minutes, *, billable=True, running=False):
    """An entry started at ``started_at``, stopped ``minutes`` later unless
    ``running``."""
    return TimeEntry.objects.create(
        org=project.org,
        project=project,
        profile=profile,
        started_at=started_at,
        ended_at=None if running else started_at + datetime.timedelta(minutes=minutes),
        billable=billable,
        hourly_rate=Decimal("100"),
        currency=project.currency,
        description="Work",
    )
