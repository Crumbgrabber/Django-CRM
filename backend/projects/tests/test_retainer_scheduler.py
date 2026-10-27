"""The hourly retainer job, its notification, and "Bill this month"
(`POST /api/projects/<id>/retainer/bill/`), racing each other included."""

import datetime
from decimal import Decimal
from unittest.mock import patch
from zoneinfo import ZoneInfo

import crum
import pytest
from celery.schedules import crontab

from accounts.models import Account
from common.models import Notification, Profile, User
from common.module_settings import change_modules
from common.testing import restore_rls_context, rls_org, set_modules_off
from contacts.models import Contact
from crm.celery import app
from invoices.models import Invoice
from projects import access, retainers
from projects.models import Project
from projects.tasks import draft_retainer_invoices
from projects.tests.conftest import log_at, make_project, make_retainer

SEPTEMBER = datetime.date(2026, 9, 1)
OCTOBER = datetime.date(2026, 10, 1)
NOVEMBER = datetime.date(2026, 11, 1)


def at(*parts, tz="UTC"):
    return datetime.datetime(*parts, tzinfo=ZoneInfo(tz))


def run_job():
    try:
        draft_retainer_invoices()
    finally:
        restore_rls_context()


def bill_url(project):
    return f"/api/projects/{project.id}/retainer/bill/"


def titles():
    return list(
        Invoice.objects.order_by("invoice_number").values_list(
            "invoice_title", flat=True
        )
    )


def next_month(project):
    project.refresh_from_db()
    return project.retainer_next_month


def test_the_beat_entry_runs_the_job_hourly():
    assert app.conf.beat_schedule["draft-retainer-invoices"] == {
        "task": "projects.tasks.draft_retainer_invoices",
        "schedule": crontab(minute=20),
    }
    assert draft_retainer_invoices.name == "projects.tasks.draft_retainer_invoices"


@pytest.mark.django_db
class TestTheJob:
    def test_drafts_an_ended_month_and_not_the_open_one(
        self, org_a, account, admin_profile, clock
    ):
        project = make_retainer(org_a, account)
        october = log_at(project, admin_profile, at(2026, 10, 20, 9), 60)
        november = log_at(project, admin_profile, at(2026, 11, 1, 0, 5), 10)
        clock.set(2026, 11, 1, 0, 20)

        run_job()
        clock.set(2026, 11, 20, 0, 20)
        run_job()

        invoice = Invoice.objects.get()
        assert invoice.invoice_title == "Site build, retainer October 2026"
        assert set(invoice.time_entries.all()) == {october}
        november.refresh_from_db()
        assert november.invoice_id is None
        assert next_month(project) == NOVEMBER

    def test_not_the_open_month_when_the_button_billed_the_ended_one_first(
        self, org_a, account, admin_profile, admin_user, clock
    ):
        project = make_retainer(org_a, account)
        log_at(project, admin_profile, at(2026, 11, 1, 0, 5), 10)
        clock.set(2026, 11, 1, 0, 20)
        real = retainers.bill_month
        button = []

        def racing(pk, org, today, **kwargs):
            # The button takes the lock between the job's listing and its own.
            if not button:
                button.append(real(pk, org, today, user=admin_user, open_month=True))
            return real(pk, org, today, **kwargs)

        with patch("projects.tasks.bill_month", side_effect=racing):
            run_job()

        invoice = Invoice.objects.get()
        assert invoice.pk == button[0].pk
        assert (invoice.created_by_id, invoice.invoice_title) == (
            admin_user.id,
            "Site build, retainer October 2026",
        )
        assert next_month(project) == NOVEMBER

    def test_a_completed_project_bills_its_last_month_once_then_nothing(
        self, admin_client, org_a, account, clock
    ):
        project = make_retainer(org_a, account)
        response = admin_client.patch(
            f"/api/projects/{project.id}/", {"status": "completed"}, "json"
        )
        assert response.status_code == 200

        clock.set(2026, 11, 1, 1)
        run_job()
        clock.set(2026, 12, 1, 1)
        run_job()

        assert titles() == ["Site build, retainer October 2026"]
        refused = admin_client.post(bill_url(project))
        assert refused.json() == {
            "error": True,
            "message": "This retainer is not running. Make the project active to bill it.",
        }

    def test_an_on_hold_project_with_no_last_month_is_skipped(
        self, org_a, account, clock
    ):
        project = make_retainer(org_a, account, status="on_hold")
        clock.set(2026, 11, 1, 1)

        run_job()

        assert not Invoice.objects.exists()
        assert next_month(project) == OCTOBER

    def test_other_billing_types_are_never_drafted(self, org_a, account, clock):
        make_project(
            org_a, account, retainer_fee=Decimal("10"), retainer_next_month=OCTOBER
        )
        clock.set(2026, 11, 1, 1)

        run_job()

        assert not Invoice.objects.exists()

    def test_admins_are_notified_once_per_invoice_and_members_not(
        self, org_a, account, admin_profile, user_profile, admin_user, clock
    ):
        second = Profile.objects.create(
            user=User.objects.create_user(email="boss@test.com", password="x"),
            org=org_a,
            role="ADMIN",
            is_active=True,
        )
        Profile.objects.create(
            user=User.objects.create_user(email="gone@test.com", password="x"),
            org=org_a,
            role="ADMIN",
            is_active=False,
        )
        project = make_retainer(
            org_a,
            account,
            created_by=admin_user,
            assigned=[user_profile],
            retainer_next_month=SEPTEMBER,
        )
        clock.set(2026, 11, 1, 1)

        run_job()

        september, october = Invoice.objects.order_by("invoice_number")
        rows = Notification.objects.filter(verb="project.retainer_invoice")
        assert sorted(rows.values_list("recipient_id", "link")) == sorted(
            (person.id, f"/invoices/{invoice.id}")
            for person in (admin_profile, second)
            for invoice in (september, october)
        )
        row = rows.get(recipient=admin_profile, link=f"/invoices/{september.id}")
        assert (row.entity_type, row.entity_id) == ("Project", project.id)
        assert row.data == {
            "project": "Site build",
            "month": "2026-09",
            "invoice_number": september.invoice_number,
        }
        assert not Notification.objects.filter(recipient=user_profile).exists()

    def test_skips_an_org_with_projects_or_invoices_off(self, org_a, account, clock):
        make_retainer(org_a, account)
        clock.set(2026, 11, 1, 1)

        for off in ("projects", "invoices"):
            set_modules_off(org_a, off)
            run_job()

        assert not Invoice.objects.exists()

    def test_a_failing_project_does_not_stop_the_others(
        self, org_a, account, clock, caplog
    ):
        broken = make_retainer(org_a, account, name="Broken")
        fine = make_retainer(org_a, account, name="Fine")
        clock.set(2026, 11, 1, 1)
        real = retainers.bill_month

        def flaky(pk, *args, **kwargs):
            if pk == broken.pk:
                raise RuntimeError("boom")
            return real(pk, *args, **kwargs)

        with patch("projects.tasks.bill_month", side_effect=flaky):
            run_job()

        assert titles() == ["Fine, retainer October 2026"]
        assert next_month(broken) == OCTOBER
        assert next_month(fine) == NOVEMBER
        assert f"project {broken.pk}" in caplog.text

    def test_two_missed_months_draft_in_order_with_rollover(
        self, org_a, account, admin_profile, clock
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_next_month=SEPTEMBER,
            retainer_hours=Decimal("10"),
            retainer_overage_rate=Decimal("100"),
            retainer_rollover=True,
        )
        log_at(project, admin_profile, at(2026, 9, 10, 9), 6 * 60)
        log_at(project, admin_profile, at(2026, 10, 10, 9), 12 * 60)
        clock.set(2026, 11, 1, 2)

        run_job()

        assert titles() == [
            "Site build, retainer September 2026",
            "Site build, retainer October 2026",
        ]
        for invoice in Invoice.objects.all():
            assert invoice.line_items.count() == 1
        project.refresh_from_db()
        assert (project.retainer_next_month, project.retainer_carried_hours) == (
            NOVEMBER,
            Decimal("2.00"),
        )

    @pytest.mark.parametrize("module", ["projects", "invoices"])
    def test_months_ended_while_a_module_was_off_are_skipped(
        self, org_a, account, admin_profile, clock, module
    ):
        clock.set(2026, 8, 20, 12)
        project = make_retainer(
            org_a, account, retainer_next_month=datetime.date(2026, 8, 1)
        )
        assert (
            change_modules(org_a, admin_profile, {"off": [module], "order": []}) == {}
        )

        clock.set(2026, 9, 1, 1)
        run_job()
        assert not Invoice.objects.exists()

        clock.set(2026, 10, 14, 12)
        assert change_modules(org_a, admin_profile, {"off": [], "order": []}) == {}
        clock.set(2026, 11, 1, 1)
        run_job()

        assert titles() == ["Site build, retainer October 2026"]
        assert next_month(project) == NOVEMBER


@pytest.mark.django_db
class TestTheButton:
    def test_a_member_is_refused_before_anything_else(
        self, user_client, org_a, account, admin_user, user_profile, clock
    ):
        mine = make_retainer(
            org_a, account, created_by=admin_user, assigned=[user_profile]
        )
        hidden = make_retainer(org_a, account, created_by=admin_user)

        for project in (mine, hidden):
            response = user_client.post(bill_url(project))
            assert response.status_code == 403
            assert response.json() == {
                "error": True,
                "message": "Only admins can bill a project.",
            }
        assert not Invoice.objects.exists()

    def test_another_orgs_project_is_not_found(self, admin_client, org_b, clock):
        with rls_org(org_b):
            theirs = make_retainer(org_b, Account.objects.create(name="B", org=org_b))

        response = admin_client.post(bill_url(theirs))

        assert response.status_code == 404
        with rls_org(org_b):
            assert not Invoice.objects.exists()

    @pytest.mark.parametrize("off", ["invoices", "projects"])
    def test_needs_projects_and_invoices(
        self, admin_client, org_a, account, clock, off
    ):
        project = make_retainer(org_a, account)
        set_modules_off(org_a, off)

        response = admin_client.post(bill_url(project))

        assert response.status_code == 404
        assert (response.json()["code"], response.json()["module"]) == (
            "module_off",
            off,
        )
        assert not Invoice.objects.exists()

    @pytest.mark.parametrize(
        "fields, message",
        [
            ({"billing_type": "fixed_fee"}, "This project is not on a retainer."),
            ({"retainer_next_month": NOVEMBER}, "This month is already billed."),
            (
                {
                    "retainer_next_month": NOVEMBER,
                    "start_date": datetime.date(2026, 11, 20),
                },
                "This retainer starts in November 2026.",
            ),
            (
                {
                    "retainer_next_month": NOVEMBER,
                    "start_date": datetime.date(2026, 10, 2),
                },
                "This month is already billed.",
            ),
            ({"retainer_last_month": SEPTEMBER}, "This retainer has ended."),
            (
                {"status": "on_hold", "retainer_last_month": SEPTEMBER},
                "This retainer is not running. Make the project active to bill it.",
            ),
            (
                {
                    "status": "completed",
                    "retainer_next_month": NOVEMBER,
                    "retainer_last_month": OCTOBER,
                },
                "This retainer is not running. Make the project active to bill it.",
            ),
        ],
    )
    def test_refusals(self, admin_client, org_a, account, clock, fields, message):
        project = make_retainer(org_a, account, **fields)

        response = admin_client.post(bill_url(project))

        assert response.status_code == 400
        assert response.json() == {"error": True, "message": message}
        assert not Invoice.objects.exists()

    def test_bills_the_open_month_through_today(
        self,
        admin_client,
        org_a,
        account,
        admin_profile,
        user_profile,
        admin_user,
        clock,
    ):
        contact = Contact.objects.create(first_name="Ana", last_name="R", org=org_a)
        account.contacts.add(contact)
        project = make_retainer(org_a, account)
        early = log_at(project, admin_profile, at(2026, 10, 3, 9), 60)
        today = log_at(project, user_profile, at(2026, 10, 14, 9), 30)
        ahead = log_at(project, admin_profile, at(2026, 10, 15, 9), 30)

        response = admin_client.post(bill_url(project))

        assert response.status_code == 201, response.json()
        invoice = Invoice.objects.get()
        assert response.json() == {
            "invoice_id": str(invoice.id),
            "invoice_number": invoice.invoice_number,
            "month": "2026-10",
        }
        assert (invoice.created_by_id, invoice.contact_id) == (
            admin_user.id,
            contact.id,
        )
        assert set(invoice.time_entries.all()) == {early, today}
        ahead.refresh_from_db()
        assert ahead.invoice_id is None
        assert next_month(project) == NOVEMBER
        assert not Notification.objects.exists()
        again = admin_client.post(bill_url(project))
        assert again.json()["message"] == "This month is already billed."
        clock.set(2026, 11, 1, 1)
        run_job()
        assert Invoice.objects.count() == 1

    @pytest.mark.parametrize(
        "month", ["2026-13", "10-2026", "", "October", 202610, "0000-01"]
    )
    def test_a_malformed_month_is_refused(
        self, admin_client, org_a, account, clock, month
    ):
        project = make_retainer(org_a, account)

        response = admin_client.post(bill_url(project), {"month": month}, "json")

        assert response.status_code == 400
        assert response.json() == {
            "error": True,
            "errors": {"month": ["Send a month as YYYY-MM."]},
        }
        assert not Invoice.objects.exists()

    def test_the_month_shown_must_still_be_the_next_one(
        self, admin_client, org_a, account, clock
    ):
        project = make_retainer(org_a, account)
        clock.set(2026, 11, 1, 8)
        run_job()

        stale = admin_client.post(bill_url(project), {"month": "2026-10"}, "json")
        current = admin_client.post(bill_url(project), {"month": "2026-11"}, "json")

        assert stale.status_code == 400
        assert stale.json() == {
            "error": True,
            "message": "This month is already billed.",
        }
        assert current.status_code == 201
        assert current.json()["month"] == "2026-11"
        assert titles() == [
            "Site build, retainer October 2026",
            "Site build, retainer November 2026",
        ]

    def test_a_project_deleted_while_billing_is_not_found(
        self, admin_client, org_a, account, clock
    ):
        project = make_retainer(org_a, account)
        real = access.get_visible_project

        def deleted_after_lookup(profile, pk):
            found = real(profile, pk)
            Project.objects.filter(pk=pk).delete()
            return found

        with patch.object(
            access, "get_visible_project", side_effect=deleted_after_lookup
        ):
            response = admin_client.post(bill_url(project))

        assert response.status_code == 404
        assert response.json() == {"error": True, "errors": "Project not found."}
        assert not Invoice.objects.exists()

    def test_bills_an_ended_month_the_job_has_not_reached(
        self, admin_client, org_a, account, clock
    ):
        project = make_retainer(org_a, account)
        clock.set(2026, 11, 1, 0, 5)

        response = admin_client.post(bill_url(project))

        assert response.status_code == 201
        assert response.json()["month"] == "2026-10"
        assert titles() == ["Site build, retainer October 2026"]
        assert next_month(project) == NOVEMBER

    def test_the_button_after_the_scheduler_answers_already_billed(
        self, admin_client, org_a, account, clock
    ):
        project = make_retainer(org_a, account)
        clock.set(2026, 11, 1, 0, 25)
        real = access.get_visible_project

        def scheduler_first(profile, pk):
            # The job drafts October after this request read the project, as a
            # worker would: with no request user to stamp.
            found = real(profile, pk)
            with crum.impersonate(None):
                run_job()
            return found

        with patch.object(access, "get_visible_project", side_effect=scheduler_first):
            response = admin_client.post(bill_url(project))

        assert response.status_code == 400
        assert response.json() == {
            "error": True,
            "message": "This month is already billed.",
        }
        invoice = Invoice.objects.get()
        assert (invoice.created_by_id, invoice.invoice_title) == (
            None,
            "Site build, retainer October 2026",
        )
        assert next_month(project) == NOVEMBER


@pytest.mark.django_db
class TestAnEditDuringABill:
    @pytest.mark.parametrize("who", ["admin", "member"])
    def test_an_edit_never_undoes_a_bill_that_landed_meanwhile(
        self,
        admin_client,
        user_client,
        org_a,
        account,
        admin_profile,
        admin_user,
        user_profile,
        clock,
        who,
    ):
        project = make_retainer(
            org_a,
            account,
            created_by=admin_user,
            assigned=[user_profile],
            retainer_hours=Decimal("10"),
            retainer_overage_rate=Decimal("100"),
            retainer_rollover=True,
        )
        log_at(project, admin_profile, at(2026, 10, 5, 9), 4 * 60)
        clock.set(2026, 11, 1, 0, 25)
        real = access.get_visible_project

        def job_after_read(profile, pk):
            found = real(profile, pk)
            with crum.impersonate(None):
                run_job()
            return found

        client = admin_client if who == "admin" else user_client
        with patch.object(access, "get_visible_project", side_effect=job_after_read):
            response = client.patch(
                f"/api/projects/{project.id}/", {"name": "Renamed"}, "json"
            )

        assert response.status_code == 200
        project.refresh_from_db()
        assert project.name == "Renamed"
        assert (project.retainer_next_month, project.retainer_carried_hours) == (
            NOVEMBER,
            Decimal("6.00"),
        )
        clock.set(2026, 11, 1, 1, 20)
        run_job()
        assert titles() == ["Site build, retainer October 2026"]
