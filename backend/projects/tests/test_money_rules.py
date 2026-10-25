"""Who may set a project's money, when its currency may change, the rate on a
member's project time, and the money a member is shown."""

import datetime
from decimal import Decimal

import pytest
from django.utils import timezone

from accounts.models import Account
from cases.models import Case, TimeEntry
from common.testing import set_modules_off
from invoices.models import Invoice
from projects.models import Project, ProjectRate
from projects.tests.conftest import log_time, make_project

URL = "/api/projects/"
MONEY = {
    "billing_type": "fixed_fee",
    "currency": "GBP",
    "budget_hours": "40",
    "budget_amount": "5000",
    "hourly_rate": "120",
}


def detail(project):
    return f"{URL}{project.id}/"


def manual(**extra):
    end = timezone.now() - datetime.timedelta(hours=1)
    return {
        "started_at": (end - datetime.timedelta(hours=1)).isoformat(),
        "ended_at": end.isoformat(),
        "description": "Work",
        "billable": True,
        **extra,
    }


@pytest.mark.django_db
class TestMoneyFieldsAreAdminOnly:
    def test_a_member_creates_with_the_defaults(
        self, user_client, org_a, member_account, user_profile
    ):
        org_a.default_currency = "EUR"
        org_a.save()

        response = user_client.post(
            URL,
            {
                "name": "Audit",
                "account": str(member_account.id),
                **MONEY,
                "rates": [{"profile": str(user_profile.id), "hourly_rate": "500"}],
            },
            format="json",
        )

        assert response.status_code == 201, response.json()
        project = Project.objects.get(pk=response.json()["id"])
        assert (project.billing_type, project.currency) == ("time_and_materials", "EUR")
        assert (project.budget_hours, project.budget_amount, project.hourly_rate) == (
            None,
            None,
            None,
        )
        assert not project.rates.exists()

    def test_an_admin_sets_them(self, admin_client, account, user_profile):
        response = admin_client.post(
            URL,
            {
                "name": "Audit",
                "account": str(account.id),
                **MONEY,
                "rates": [{"profile": str(user_profile.id), "hourly_rate": "90"}],
            },
            format="json",
        )

        assert response.status_code == 201
        project = Project.objects.get(pk=response.json()["id"])
        assert (project.billing_type, project.currency) == ("fixed_fee", "GBP")
        assert (project.budget_hours, project.budget_amount, project.hourly_rate) == (
            Decimal("40.00"),
            Decimal("5000.00"),
            Decimal("120.00"),
        )
        assert project.rates.get().hourly_rate == Decimal("90.00")

    def test_a_members_patch_leaves_money_and_account_alone(
        self, user_client, admin_client, org_a, account, admin_user, user_profile
    ):
        other = Account.objects.create(name="Other", org=org_a, created_by=admin_user)
        project = make_project(
            org_a,
            account,
            created_by=admin_user,
            assigned=[user_profile],
            hourly_rate=Decimal("50"),
        )
        ProjectRate.objects.create(
            org=org_a, project=project, profile=user_profile, hourly_rate=50
        )
        change = {
            **MONEY,
            "account": str(other.id),
            "rates": [],
            "name": "Renamed",
        }

        member = user_client.patch(detail(project), change, format="json")
        project.refresh_from_db()

        assert member.status_code == 200
        assert project.name == "Renamed"
        assert (project.account_id, project.hourly_rate, project.currency) == (
            account.id,
            Decimal("50.00"),
            "USD",
        )
        assert (project.billing_type, project.budget_amount) == (
            "time_and_materials",
            None,
        )
        assert project.rates.count() == 1

        admin = admin_client.patch(detail(project), change, format="json")
        project.refresh_from_db()

        assert admin.status_code == 200
        assert (project.account_id, project.hourly_rate, project.currency) == (
            other.id,
            Decimal("120.00"),
            "GBP",
        )
        assert not project.rates.exists()


@pytest.mark.django_db
class TestCurrencyChange:
    def test_refused_once_there_is_time_or_an_invoice(
        self, admin_client, org_a, account, admin_profile
    ):
        with_time = make_project(org_a, account, name="Timed")
        log_time(with_time, admin_profile, 30)
        with_invoice = make_project(org_a, account, name="Invoiced")
        Invoice.objects.create(
            invoice_title="X", account=account, org=org_a, project=with_invoice
        )
        empty = make_project(org_a, account, name="Empty")

        for project in (with_time, with_invoice):
            response = admin_client.patch(
                detail(project), {"currency": "EUR"}, format="json"
            )
            assert response.status_code == 400
            assert response.json()["errors"]["currency"] == [
                "The currency cannot change once the project has time or invoices."
            ]
            project.refresh_from_db()
            assert project.currency == "USD"
        same = admin_client.patch(detail(with_time), {"currency": "USD"}, format="json")
        assert same.status_code == 200
        allowed = admin_client.patch(detail(empty), {"currency": "EUR"}, format="json")
        assert allowed.status_code == 200
        empty.refresh_from_db()
        assert empty.currency == "EUR"


@pytest.mark.django_db
class TestRateOnProjectTime:
    @pytest.fixture
    def project(self, org_a, account, admin_user, user_profile):
        project = make_project(
            org_a,
            account,
            created_by=admin_user,
            assigned=[user_profile],
            hourly_rate=Decimal("80"),
        )
        return project

    def url(self, project, start=False):
        return f"{URL}{project.id}/time-entries/" + ("start/" if start else "")

    def test_a_members_typed_rate_is_ignored_on_create(
        self, user_client, admin_client, project
    ):
        member = user_client.post(
            self.url(project), manual(hourly_rate="999"), format="json"
        )
        admin = admin_client.post(
            self.url(project), manual(hourly_rate="10"), format="json"
        )

        assert member.json()["hourly_rate"] == "80.00"
        assert admin.json()["hourly_rate"] == "10.00"

    def test_a_members_typed_rate_is_ignored_on_start(self, user_client, project):
        body = user_client.post(
            self.url(project, start=True), {"hourly_rate": "999"}, format="json"
        ).json()

        assert body["hourly_rate"] == "80.00"

    def test_a_members_rate_edit_is_ignored_on_put(
        self, user_client, admin_client, project, user_profile
    ):
        entry = log_time(project, user_profile, 30, rate="80")
        url = f"/api/time-entries/{entry.id}/"

        member = user_client.put(
            url, {"hourly_rate": "999", "description": "Edited"}, format="json"
        )
        admin = admin_client.put(url, {"hourly_rate": "70"}, format="json")

        assert member.status_code == 200
        assert member.json()["description"] == "Edited"
        assert member.json()["hourly_rate"] == "80.00"
        assert admin.json()["hourly_rate"] == "70.00"

    def test_ticket_time_keeps_a_members_typed_rate(
        self, user_client, org_a, regular_user, user_profile
    ):
        case = Case.objects.create(
            name="T",
            status="New",
            priority="Normal",
            org=org_a,
            created_by=regular_user,
        )
        case.assigned_to.add(user_profile)

        body = user_client.post(
            f"/api/cases/{case.id}/time-entries/",
            manual(hourly_rate="999"),
            format="json",
        ).json()
        entry = TimeEntry.objects.get(pk=body["id"])
        edited = user_client.put(
            f"/api/time-entries/{entry.id}/", {"hourly_rate": "5"}, format="json"
        ).json()

        assert body["hourly_rate"] == "999.00"
        assert edited["hourly_rate"] == "5.00"


@pytest.mark.django_db
class TestUnratedAndInvoicedFigures:
    def test_unbilled_counts_entries_with_no_rate(
        self, admin_client, org_a, account, admin_profile
    ):
        project = make_project(org_a, account)
        log_time(project, admin_profile, 30, rate="100")
        log_time(project, admin_profile, 30, rate=None)
        log_time(project, admin_profile, 30, rate=None, billable=False)

        body = admin_client.get(f"{URL}{project.id}/unbilled/").json()

        assert body == {
            "entry_count": 2,
            "hours": "1.00",
            "value": "50.00",
            "currency": "USD",
            "unrated_count": 1,
        }

    def test_invoiced_amount_is_for_admins_and_needs_invoices(
        self, admin_client, user_client, org_a, account, regular_user
    ):
        project = make_project(org_a, account, created_by=regular_user)
        invoice = Invoice.objects.create(
            invoice_title="X", account=account, org=org_a, project=project
        )
        Invoice.objects.filter(pk=invoice.pk).update(total_amount=Decimal("300"))

        assert admin_client.get(detail(project)).json()["burn"]["invoiced_amount"] == (
            "300.00"
        )
        assert (
            user_client.get(detail(project)).json()["burn"]["invoiced_amount"] is None
        )
        rows = user_client.get(URL).json()["projects"]
        assert rows[0]["burn"]["invoiced_amount"] is None

        set_modules_off(org_a, "invoices")
        assert (
            admin_client.get(detail(project)).json()["burn"]["invoiced_amount"] is None
        )
