import datetime
from decimal import Decimal

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
