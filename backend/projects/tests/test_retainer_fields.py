"""A project's retainer fields: who may set them, what a retainer requires,
and the month rules every create and edit applies."""

import datetime
from decimal import Decimal

import pytest

from common.testing import restore_rls_context, set_modules_off
from invoices.models import Invoice
from projects.models import Project
from projects.tasks import draft_retainer_invoices
from projects.tests.conftest import make_project, make_retainer

URL = "/api/projects/"
RETAINER = {
    "billing_type": "retainer",
    "retainer_fee": "1500",
    "retainer_hours": "10",
    "retainer_rollover": True,
    "retainer_overage_rate": "120",
}
OCTOBER = datetime.date(2026, 10, 1)


def detail(project):
    return f"{URL}{project.id}/"


def titles():
    return list(
        Invoice.objects.order_by("invoice_number").values_list(
            "invoice_title", flat=True
        )
    )


def run_job():
    try:
        draft_retainer_invoices()
    finally:
        restore_rls_context()


def stored(project):
    project.refresh_from_db()
    return {
        name: getattr(project, name)
        for name in (
            "billing_type",
            "status",
            "retainer_fee",
            "retainer_hours",
            "retainer_rollover",
            "retainer_overage_rate",
            "retainer_carried_hours",
            "retainer_next_month",
            "retainer_last_month",
        )
    }


@pytest.mark.django_db
class TestFields:
    def test_an_admin_creates_a_retainer(self, admin_client, account, clock):
        response = admin_client.post(
            URL, {"name": "Support", "account": str(account.id), **RETAINER}, "json"
        )

        assert response.status_code == 201, response.json()
        body = response.json()["project"]
        assert {k: body[k] for k in RETAINER} == {
            "billing_type": "retainer",
            "retainer_fee": "1500.00",
            "retainer_hours": "10.00",
            "retainer_rollover": True,
            "retainer_overage_rate": "120.00",
        }
        assert body["retainer_carried_hours"] == "0.00"
        assert (body["retainer_next_month"], body["retainer_last_month"]) == (
            "2026-10-01",
            None,
        )
        listed = admin_client.get(URL).json()["projects"][0]
        assert listed["retainer_fee"] == "1500.00"
        assert listed["retainer_next_month"] == "2026-10-01"

    def test_the_carried_hours_can_be_corrected_or_cleared(
        self, admin_client, org_a, account
    ):
        project = make_retainer(org_a, account, retainer_carried_hours=Decimal("4"))

        fixed = admin_client.patch(
            detail(project), {"retainer_carried_hours": "1.5"}, "json"
        )
        assert fixed.status_code == 200
        assert fixed.json()["project"]["retainer_carried_hours"] == "1.50"
        cleared = admin_client.patch(
            detail(project), {"retainer_carried_hours": "0"}, "json"
        )
        assert cleared.json()["project"]["retainer_carried_hours"] == "0.00"

    @pytest.mark.parametrize(
        "change, field, message",
        [
            ({"retainer_fee": None}, "retainer_fee", "Set the monthly fee."),
            ({"retainer_overage_rate": None}, "retainer_overage_rate", None),
            ({"retainer_fee": "0"}, "retainer_fee", None),
            ({"retainer_hours": "-1"}, "retainer_hours", None),
            (
                {"retainer_hours": "744.01"},
                "retainer_hours",
                "At most 744 hours, the hours in a month.",
            ),
            ({"retainer_overage_rate": "-0.01"}, "retainer_overage_rate", None),
            ({"retainer_carried_hours": "-1"}, "retainer_carried_hours", None),
            ({"retainer_carried_hours": None}, "retainer_carried_hours", None),
            ({"retainer_rollover": "maybe"}, "retainer_rollover", None),
        ],
    )
    def test_bad_values_are_refused_and_nothing_is_written(
        self, admin_client, account, change, field, message
    ):
        body = {"name": "Support", "account": str(account.id), **RETAINER, **change}

        response = admin_client.post(URL, body, "json")

        assert response.status_code == 400
        assert response.json()["error"] is True
        assert field in response.json()["errors"]
        if message:
            assert response.json()["errors"][field] == [message]
        assert not Project.objects.exists()

    def test_hours_need_the_overage_rate(self, admin_client, account):
        body = {"name": "Support", "account": str(account.id), **RETAINER}
        del body["retainer_overage_rate"]

        response = admin_client.post(URL, body, "json")

        assert response.status_code == 400
        assert response.json()["errors"] == {
            "retainer_overage_rate": ["Set the rate for hours over the allowance."]
        }
        without_hours = {**body, "retainer_hours": None}
        assert admin_client.post(URL, without_hours, "json").status_code == 201

    def test_a_switch_is_judged_against_what_is_stored(
        self, admin_client, org_a, account
    ):
        project = make_project(org_a, account, retainer_hours=Decimal("5"))

        bare = admin_client.patch(detail(project), {"billing_type": "retainer"}, "json")

        assert bare.status_code == 400
        assert set(bare.json()["errors"]) == {"retainer_fee", "retainer_overage_rate"}
        assert stored(project)["billing_type"] == "time_and_materials"
        filled = admin_client.patch(
            detail(project),
            {
                "billing_type": "retainer",
                "retainer_fee": "800",
                "retainer_overage_rate": "90",
            },
            "json",
        )
        assert filled.status_code == 200

    def test_a_month_of_hours_is_the_most_an_allowance_holds(
        self, admin_client, account
    ):
        body = {"name": "Support", "account": str(account.id), **RETAINER}

        response = admin_client.post(URL, {**body, "retainer_hours": "744"}, "json")

        assert response.status_code == 201
        assert response.json()["project"]["retainer_hours"] == "744.00"

    def test_other_billing_types_keep_retainer_values_unused(
        self, admin_client, account
    ):
        response = admin_client.post(
            URL,
            {
                "name": "Build",
                "account": str(account.id),
                "billing_type": "fixed_fee",
                "retainer_hours": "10",
            },
            "json",
        )

        assert response.status_code == 201
        body = response.json()["project"]
        assert (body["retainer_hours"], body["retainer_next_month"]) == ("10.00", None)
        assert body["retainer_usage"] is None


@pytest.mark.django_db
class TestMembers:
    EVERYTHING = {
        **RETAINER,
        "retainer_fee": "1",
        "retainer_hours": "999",
        "retainer_rollover": False,
        "retainer_carried_hours": "50",
        "billing_type": "time_and_materials",
        "status": "completed",
    }

    def test_a_members_write_leaves_a_retainer_as_it_was(
        self, user_client, admin_client, org_a, account, admin_user, user_profile
    ):
        project = make_retainer(
            org_a,
            account,
            created_by=admin_user,
            assigned=[user_profile],
            retainer_hours=Decimal("10"),
            retainer_overage_rate=Decimal("120"),
            retainer_rollover=True,
            retainer_carried_hours=Decimal("2"),
        )
        before = stored(project)

        member = user_client.patch(
            detail(project), {**self.EVERYTHING, "name": "Renamed"}, "json"
        )

        assert member.status_code == 200
        assert stored(project) == before
        assert project.name == "Renamed"
        admin = admin_client.patch(detail(project), {"status": "on_hold"}, "json")
        assert admin.status_code == 200
        assert stored(project)["status"] == "on_hold"

    def test_a_member_still_sets_the_status_of_other_projects(
        self, user_client, org_a, account, admin_user, user_profile
    ):
        project = make_project(
            org_a, account, created_by=admin_user, assigned=[user_profile]
        )

        response = user_client.patch(detail(project), {"status": "on_hold"}, "json")

        assert response.status_code == 200
        assert stored(project)["status"] == "on_hold"

    def test_only_an_admin_deletes_a_retainer(
        self, user_client, admin_client, org_a, member_account, regular_user
    ):
        retainer = make_retainer(org_a, member_account, created_by=regular_user)
        hourly = make_project(org_a, member_account, created_by=regular_user)

        refused = user_client.delete(detail(retainer))
        allowed = user_client.delete(detail(hourly))

        assert refused.status_code == 403
        assert allowed.status_code == 204
        assert user_client.get(detail(retainer)).json()["can_delete"] is False
        assert admin_client.delete(detail(retainer)).status_code == 204
        assert not Project.objects.exists()

    def test_a_member_cannot_create_a_retainer(self, user_client, member_account):
        response = user_client.post(
            URL,
            {"name": "Support", "account": str(member_account.id), **RETAINER},
            "json",
        )

        assert response.status_code == 201
        project = Project.objects.get(pk=response.json()["id"])
        assert stored(project)["billing_type"] == "time_and_materials"
        assert (project.retainer_fee, project.retainer_next_month) == (None, None)


@pytest.mark.django_db
class TestMonthRules:
    def create(self, client, account, **extra):
        response = client.post(
            URL,
            {"name": "Support", "account": str(account.id), **RETAINER, **extra},
            "json",
        )
        assert response.status_code == 201, response.json()
        return Project.objects.get(pk=response.json()["id"])

    def test_becoming_a_retainer_starts_this_month_with_nothing_carried(
        self, admin_client, org_a, account, clock
    ):
        project = make_project(
            org_a,
            account,
            start_date=datetime.date(2026, 1, 5),
            retainer_carried_hours=Decimal("7"),
        )

        admin_client.patch(detail(project), RETAINER, "json")

        state = stored(project)
        assert (state["retainer_next_month"], state["retainer_last_month"]) == (
            OCTOBER,
            None,
        )
        assert state["retainer_carried_hours"] == Decimal("0")

    def test_a_start_date_next_month_starts_billing_then(
        self, admin_client, account, clock
    ):
        project = self.create(admin_client, account, start_date="2026-11-20")

        assert stored(project)["retainer_next_month"] == datetime.date(2026, 11, 1)

    def test_created_on_hold_bills_nothing_until_active(
        self, admin_client, account, clock
    ):
        project = self.create(admin_client, account, status="on_hold")

        state = stored(project)
        assert (state["retainer_next_month"], state["retainer_last_month"]) == (
            OCTOBER,
            datetime.date(2026, 9, 1),
        )
        clock.set(2026, 12, 3, 9)
        admin_client.patch(detail(project), {"status": "active"}, "json")
        state = stored(project)
        assert (state["retainer_next_month"], state["retainer_last_month"]) == (
            datetime.date(2026, 12, 1),
            None,
        )

    def test_switched_to_a_retainer_while_on_hold_bills_nothing(
        self, admin_client, org_a, account, clock
    ):
        project = make_project(org_a, account)

        admin_client.patch(detail(project), {**RETAINER, "status": "on_hold"}, "json")

        state = stored(project)
        assert (state["retainer_next_month"], state["retainer_last_month"]) == (
            OCTOBER,
            datetime.date(2026, 9, 1),
        )

    def test_leaving_active_ends_after_this_month(self, admin_client, account, clock):
        project = self.create(admin_client, account)
        clock.set(2026, 11, 18, 9)

        admin_client.patch(detail(project), {"status": "completed"}, "json")
        state = stored(project)
        assert state["retainer_last_month"] == datetime.date(2026, 11, 1)
        assert state["retainer_next_month"] == OCTOBER

        admin_client.patch(detail(project), {"status": "cancelled"}, "json")
        assert stored(project)["retainer_last_month"] == datetime.date(2026, 11, 1)

    def test_back_to_active_skips_the_months_between(
        self, admin_client, account, clock
    ):
        project = self.create(admin_client, account)
        admin_client.patch(detail(project), {"status": "on_hold"}, "json")
        clock.set(2027, 2, 10, 9)

        admin_client.patch(detail(project), {"status": "active"}, "json")

        state = stored(project)
        assert (state["retainer_next_month"], state["retainer_last_month"]) == (
            datetime.date(2027, 2, 1),
            None,
        )
        assert titles() == ["Support, retainer October 2026"]

    def test_back_to_active_drafts_the_owed_month_before_any_run(
        self, admin_client, account, admin_user, clock
    ):
        project = self.create(admin_client, account)
        admin_client.patch(detail(project), {"status": "on_hold"}, "json")
        clock.set(2026, 11, 1, 0, 10)

        response = admin_client.patch(detail(project), {"status": "active"}, "json")

        assert response.status_code == 200
        invoice = Invoice.objects.get()
        assert (invoice.invoice_title, invoice.created_by_id) == (
            "Support, retainer October 2026",
            admin_user.id,
        )
        assert [row["id"] for row in response.json()["project"]["invoices"]] == [
            str(invoice.id)
        ]
        state = stored(project)
        assert (state["retainer_next_month"], state["retainer_last_month"]) == (
            datetime.date(2026, 11, 1),
            None,
        )
        clock.set(2026, 11, 1, 0, 20)
        run_job()
        assert titles() == ["Support, retainer October 2026"]
        clock.set(2026, 12, 1, 0, 20)
        run_job()
        assert titles() == [
            "Support, retainer October 2026",
            "Support, retainer November 2026",
        ]

    def test_reactivated_later_drafts_the_owed_month_and_skips_the_rest(
        self, admin_client, account, clock
    ):
        project = self.create(admin_client, account)
        admin_client.patch(detail(project), {"status": "on_hold"}, "json")
        clock.set(2026, 12, 3, 9)

        admin_client.patch(detail(project), {"status": "active"}, "json")

        assert titles() == ["Support, retainer October 2026"]
        assert stored(project)["retainer_next_month"] == datetime.date(2026, 12, 1)
        clock.set(2027, 1, 1, 0, 20)
        run_job()
        assert titles() == [
            "Support, retainer October 2026",
            "Support, retainer December 2026",
        ]

    def test_reactivated_while_invoices_is_off_drafts_nothing(
        self, admin_client, org_a, account, clock
    ):
        project = self.create(admin_client, account)
        admin_client.patch(detail(project), {"status": "on_hold"}, "json")
        set_modules_off(org_a, "invoices")
        clock.set(2026, 11, 3, 9)

        response = admin_client.patch(detail(project), {"status": "active"}, "json")

        assert response.status_code == 200
        assert not Invoice.objects.exists()
        state = stored(project)
        assert (state["retainer_next_month"], state["retainer_last_month"]) == (
            datetime.date(2026, 11, 1),
            None,
        )

    def test_paused_and_resumed_in_one_month_drafts_nothing(
        self, admin_client, account, clock
    ):
        project = self.create(admin_client, account)
        admin_client.patch(detail(project), {"status": "on_hold"}, "json")
        clock.set(2026, 10, 20, 9)

        admin_client.patch(detail(project), {"status": "active"}, "json")

        assert not Invoice.objects.exists()
        state = stored(project)
        assert (state["retainer_next_month"], state["retainer_last_month"]) == (
            OCTOBER,
            None,
        )

    def test_back_to_active_keeps_a_later_next_month(
        self, admin_client, org_a, account, clock
    ):
        project = make_retainer(
            org_a,
            account,
            status="on_hold",
            retainer_next_month=datetime.date(2026, 12, 1),
            retainer_last_month=datetime.date(2026, 10, 1),
        )

        admin_client.patch(detail(project), {"status": "active"}, "json")

        state = stored(project)
        assert (state["retainer_next_month"], state["retainer_last_month"]) == (
            datetime.date(2026, 12, 1),
            None,
        )

    def test_a_patch_that_leaves_billing_alone_changes_no_month(
        self, admin_client, org_a, account, clock
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_next_month=datetime.date(2026, 8, 1),
            retainer_carried_hours=Decimal("3"),
        )
        before = stored(project)

        admin_client.patch(detail(project), {"name": "Renamed"}, "json")

        assert stored(project) == before

    def test_switching_to_retainer_and_back_keeps_the_values(
        self, admin_client, account, clock
    ):
        project = self.create(admin_client, account)
        Project.objects.filter(pk=project.pk).update(
            retainer_next_month=datetime.date(2026, 12, 1),
            retainer_carried_hours=Decimal("3"),
        )

        admin_client.patch(
            detail(project), {"billing_type": "time_and_materials"}, "json"
        )
        kept = stored(project)
        assert kept["billing_type"] == "time_and_materials"
        assert (kept["retainer_fee"], kept["retainer_hours"]) == (
            Decimal("1500.00"),
            Decimal("10.00"),
        )
        assert (kept["retainer_rollover"], kept["retainer_overage_rate"]) == (
            True,
            Decimal("120.00"),
        )
        assert (kept["retainer_next_month"], kept["retainer_carried_hours"]) == (
            datetime.date(2026, 12, 1),
            Decimal("3.00"),
        )

        again = admin_client.patch(
            detail(project), {"billing_type": "retainer"}, "json"
        )
        assert again.status_code == 200
        state = stored(project)
        assert state["retainer_fee"] == Decimal("1500.00")
        assert (state["retainer_next_month"], state["retainer_carried_hours"]) == (
            datetime.date(2026, 12, 1),
            Decimal("0"),
        )

    def test_switching_back_after_the_button_never_bills_the_month_again(
        self, admin_client, account, clock
    ):
        project = self.create(admin_client, account)
        assert admin_client.post(f"{detail(project)}retainer/bill/").status_code == 201

        admin_client.patch(
            detail(project), {"billing_type": "time_and_materials"}, "json"
        )
        admin_client.patch(detail(project), {"billing_type": "retainer"}, "json")
        clock.set(2026, 11, 1, 0, 20)
        run_job()

        assert titles() == ["Support, retainer October 2026"]
        assert stored(project)["retainer_next_month"] == datetime.date(2026, 11, 1)
