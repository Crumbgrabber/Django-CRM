"""Billing one retainer month (`projects.retainers.bill_month`) and the
detail's `retainer_usage`: the fee, the allowance, overage from minutes,
rollover, which time counts, and the org's calendar."""

import datetime
import threading
import time
from decimal import Decimal
from unittest import mock
from zoneinfo import ZoneInfo

import pytest
from django.db import connection

from common.testing import restore_rls_context, set_modules_off
from contacts.models import Contact
from invoices.models import Invoice
from projects import retainers
from projects.burn import unbilled_summary
from projects.retainers import bill_month
from projects.tasks import draft_retainer_invoices
from projects.tests.conftest import log_at, make_project, make_retainer

SEPTEMBER = datetime.date(2026, 9, 1)
OCTOBER = datetime.date(2026, 10, 1)
NOVEMBER = datetime.date(2026, 11, 1)
FEE = ("October 2026 retainer", Decimal("1.00"), Decimal("1000.00"))


def at(*parts, tz="UTC"):
    return datetime.datetime(*parts, tzinfo=ZoneInfo(tz))


def lines(invoice):
    return [
        (line.name, line.quantity, line.unit_price)
        for line in invoice.line_items.order_by("order")
    ]


def billed(invoice):
    return set(invoice.time_entries.values_list("id", flat=True))


def run_job():
    try:
        draft_retainer_invoices()
    finally:
        restore_rls_context()


@pytest.mark.django_db
class TestBillMonth:
    def test_fee_only(self, org_a, account, admin_profile):
        project = make_retainer(org_a, account)
        entry = log_at(project, admin_profile, at(2026, 10, 5, 9), 600)

        invoice = bill_month(project.pk, org_a, NOVEMBER)

        assert invoice.invoice_title == "Site build, retainer October 2026"
        assert lines(invoice) == [FEE]
        assert (invoice.status, invoice.project_id, invoice.account_id) == (
            "Draft",
            project.id,
            account.id,
        )
        assert (invoice.currency, invoice.tax_rate, invoice.total_amount) == (
            "USD",
            Decimal("0"),
            Decimal("1000.00"),
        )
        assert (invoice.issue_date, invoice.retainer_month) == (NOVEMBER, OCTOBER)
        assert billed(invoice) == {entry.id}
        project.refresh_from_db()
        assert (project.retainer_next_month, project.retainer_carried_hours) == (
            NOVEMBER,
            Decimal("0"),
        )

    def test_within_the_allowance(self, org_a, account, admin_profile):
        project = make_retainer(
            org_a,
            account,
            retainer_hours=Decimal("10"),
            retainer_overage_rate=Decimal("120"),
        )
        log_at(project, admin_profile, at(2026, 10, 5, 9), 600)

        assert lines(bill_month(project.pk, org_a, NOVEMBER)) == [FEE]

    def test_overage_is_at_the_rate_and_worked_out_from_minutes(
        self, org_a, account, admin_profile
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_hours=Decimal("0.5"),
            retainer_overage_rate=Decimal("120"),
        )
        for day in (5, 6, 7):
            log_at(project, admin_profile, at(2026, 10, day, 9), 20)

        invoice = bill_month(project.pk, org_a, NOVEMBER)

        assert lines(invoice) == [
            FEE,
            ("Hours over the allowance", Decimal("0.50"), Decimal("120.00")),
        ]
        assert invoice.total_amount == Decimal("1060.00")

    @pytest.mark.parametrize("rollover, carried", [(True, "6.00"), (False, "0.00")])
    def test_unused_hours_carry_only_with_rollover(
        self, org_a, account, admin_profile, rollover, carried
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_hours=Decimal("10"),
            retainer_overage_rate=Decimal("120"),
            retainer_rollover=rollover,
            retainer_carried_hours=Decimal("5"),
        )
        log_at(project, admin_profile, at(2026, 10, 5, 9), 240 + 5 * 60 * rollover)

        invoice = bill_month(project.pk, org_a, NOVEMBER)

        project.refresh_from_db()
        assert project.retainer_carried_hours == Decimal(carried)
        assert lines(invoice) == [FEE]

    def test_without_rollover_carried_hours_are_not_spent(
        self, org_a, account, admin_profile
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_hours=Decimal("2"),
            retainer_overage_rate=Decimal("100"),
            retainer_carried_hours=Decimal("5"),
        )
        log_at(project, admin_profile, at(2026, 10, 5, 9), 180)

        invoice = bill_month(project.pk, org_a, NOVEMBER)

        assert lines(invoice)[1] == (
            "Hours over the allowance",
            Decimal("1.00"),
            Decimal("100.00"),
        )

    @pytest.mark.parametrize(
        "minutes, overage, carried", [(180, None, "0.50"), (240, "0.50", "0.00")]
    )
    def test_carried_hours_are_used_before_overage(
        self, org_a, account, admin_profile, minutes, overage, carried
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_hours=Decimal("2"),
            retainer_overage_rate=Decimal("100"),
            retainer_rollover=True,
            retainer_carried_hours=Decimal("1.5"),
        )
        log_at(project, admin_profile, at(2026, 10, 5, 9), minutes)

        invoice = bill_month(project.pk, org_a, NOVEMBER)

        expected = [FEE]
        if overage:
            expected.append(
                ("Hours over the allowance", Decimal(overage), Decimal("100.00"))
            )
        assert lines(invoice) == expected
        project.refresh_from_db()
        assert project.retainer_carried_hours == Decimal(carried)

    def test_no_allowance_never_adds_an_overage_line(
        self, org_a, account, admin_profile
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_overage_rate=Decimal("100"),
            retainer_rollover=True,
            retainer_carried_hours=Decimal("3"),
        )
        log_at(project, admin_profile, at(2026, 10, 5, 9), 40 * 60)

        invoice = bill_month(project.pk, org_a, NOVEMBER)

        assert lines(invoice) == [FEE]
        project.refresh_from_db()
        assert project.retainer_carried_hours == Decimal("0")

    def test_billed_time_leaves_the_unbilled_and_later_time_waits(
        self, org_a, account, admin_profile
    ):
        project = make_retainer(org_a, account)
        late = log_at(project, admin_profile, at(2026, 9, 28, 9), 60)
        october = log_at(project, admin_profile, at(2026, 10, 31, 22), 60)
        november = log_at(project, admin_profile, at(2026, 11, 1, 0, 5), 30)

        invoice = bill_month(project.pk, org_a, datetime.date(2026, 11, 2))

        assert billed(invoice) == {late.id, october.id}
        summary = unbilled_summary(project, datetime.date(2026, 11, 2))
        assert summary["entry_count"] == 1
        november.refresh_from_db()
        assert november.invoice_id is None

    def test_non_billable_time_is_not_counted(self, org_a, account, admin_profile):
        project = make_retainer(
            org_a,
            account,
            retainer_hours=Decimal("1"),
            retainer_overage_rate=Decimal("100"),
        )
        counted = log_at(project, admin_profile, at(2026, 10, 5, 9), 30)
        free = log_at(project, admin_profile, at(2026, 10, 6, 9), 300, billable=False)

        invoice = bill_month(project.pk, org_a, NOVEMBER)

        assert lines(invoice) == [FEE]
        assert billed(invoice) == {counted.id}
        free.refresh_from_db()
        assert free.invoice_id is None

    def test_a_scheduled_draft_is_seen_by_admins_and_not_the_projects_member(
        self, org_a, account, admin_client, user_client, admin_user, user_profile
    ):
        older = Contact.objects.create(first_name="Old", last_name="C", org=org_a)
        newest = Contact.objects.create(first_name="New", last_name="C", org=org_a)
        Contact.objects.filter(pk=older.pk).update(created_at=at(2026, 1, 1))
        account.contacts.add(older, newest)
        project = make_retainer(
            org_a, account, created_by=admin_user, assigned=[user_profile]
        )

        invoice = bill_month(project.pk, org_a, NOVEMBER)

        assert (invoice.created_by_id, invoice.contact_id) == (None, newest.id)
        url = f"/api/invoices/{invoice.id}/"
        assert admin_client.get(url).status_code == 200
        assert user_client.get(url).status_code == 404
        listed = user_client.get(f"/api/projects/{project.id}/").json()["invoices"]
        assert listed == []

    def test_nothing_before_the_month_ends_unless_it_is_the_open_month(
        self, org_a, account, admin_profile
    ):
        project = make_retainer(org_a, account)
        entry = log_at(project, admin_profile, at(2026, 10, 30, 9), 60)
        last_day = datetime.date(2026, 10, 31)

        assert bill_month(project.pk, org_a, last_day) is None
        invoice = bill_month(project.pk, org_a, last_day, open_month=True)

        assert billed(invoice) == {entry.id}
        assert invoice.retainer_month == OCTOBER

    def test_never_a_later_month(self, org_a, account):
        project = make_retainer(org_a, account, retainer_next_month=NOVEMBER)

        today = datetime.date(2026, 10, 14)
        assert bill_month(project.pk, org_a, today, open_month=True) is None
        assert not Invoice.objects.exists()

    @pytest.mark.parametrize(
        "fields",
        [
            {"retainer_last_month": SEPTEMBER},
            {"billing_type": "time_and_materials"},
            {"retainer_next_month": None},
        ],
    )
    def test_an_ended_retainer_or_other_project_bills_nothing(
        self, org_a, account, fields
    ):
        project = make_retainer(org_a, account, **fields)

        assert bill_month(project.pk, org_a, NOVEMBER, open_month=True) is None
        assert not Invoice.objects.exists()

    def test_another_orgs_project_bills_nothing(self, org_a, org_b, account):
        project = make_retainer(org_a, account)

        assert bill_month(project.pk, org_b, NOVEMBER) is None
        assert not Invoice.objects.exists()

    def test_a_month_before_skip_before_moves_on_without_an_invoice(
        self, org_a, account, admin_profile
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_next_month=datetime.date(2026, 8, 1),
            retainer_hours=Decimal("10"),
            retainer_overage_rate=Decimal("100"),
            retainer_rollover=True,
            retainer_carried_hours=Decimal("3"),
        )
        entry = log_at(project, admin_profile, at(2026, 8, 5, 9), 60)
        back_on = datetime.date(2026, 10, 14)

        assert bill_month(project.pk, org_a, NOVEMBER, skip_before=back_on) is None

        project.refresh_from_db()
        assert (project.retainer_next_month, project.retainer_carried_hours) == (
            SEPTEMBER,
            Decimal("3.00"),
        )
        assert not Invoice.objects.exists()
        entry.refresh_from_db()
        assert entry.invoice_id is None

    def test_a_long_name_keeps_the_month_in_the_title(self, org_a, account):
        project = make_retainer(org_a, account, name="A" * 95)

        invoice = bill_month(project.pk, org_a, NOVEMBER)

        assert len(invoice.invoice_title) == 100
        assert invoice.invoice_title.endswith(", retainer October 2026")

    def test_with_timesheet_off_the_fee_is_billed_alone(
        self, admin_client, org_a, account, admin_profile, clock
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_hours=Decimal("1"),
            retainer_overage_rate=Decimal("100"),
            retainer_rollover=True,
            retainer_carried_hours=Decimal("2"),
        )
        entry = log_at(project, admin_profile, at(2026, 10, 5, 9), 5 * 60)
        set_modules_off(org_a, "timesheet")

        usage = admin_client.get(f"/api/projects/{project.id}/").json()[
            "retainer_usage"
        ]
        invoice = bill_month(project.pk, org_a, NOVEMBER)

        assert (usage["used_hours"], usage["overage_hours"]) == ("0.00", "0.00")
        assert lines(invoice) == [FEE]
        assert billed(invoice) == set()
        entry.refresh_from_db()
        assert entry.invoice_id is None
        project.refresh_from_db()
        assert project.retainer_carried_hours == Decimal("2.00")


@pytest.mark.django_db
class TestReviewFocus:
    @pytest.mark.parametrize("tz", ["Asia/Kolkata", "Pacific/Pitcairn"])
    def test_month_edges_follow_the_org_timezone(
        self, org_a, account, admin_profile, user_profile, clock, tz
    ):
        org_a.timezone = tz
        org_a.save(update_fields=["timezone"])
        project = make_retainer(org_a, account)
        october = log_at(project, admin_profile, at(2026, 10, 31, 23, 30, tz=tz), 20)
        november = log_at(project, user_profile, at(2026, 11, 1, 0, 0, tz=tz), 10)

        clock.set(2026, 10, 31, 23, 55, tz=tz)
        run_job()
        assert not Invoice.objects.exists()

        clock.set(2026, 11, 1, 0, 20, tz=tz)
        run_job()
        invoice = Invoice.objects.get()
        assert invoice.invoice_title.endswith("October 2026")
        assert billed(invoice) == {october.id}
        november.refresh_from_db()
        assert november.invoice_id is None

    def test_billing_a_month_twice_drafts_once(
        self, org_a, account, admin_profile, clock
    ):
        project = make_retainer(org_a, account)
        log_at(project, admin_profile, at(2026, 10, 5, 9), 60)
        clock.set(2026, 11, 1, 1)

        first = bill_month(project.pk, org_a, NOVEMBER)
        second = bill_month(project.pk, org_a, NOVEMBER)
        run_job()
        run_job()

        assert first is not None and second is None
        assert list(Invoice.objects.values_list("id", flat=True)) == [first.id]
        project.refresh_from_db()
        assert project.retainer_next_month == NOVEMBER

    def test_a_running_timer_waits_for_the_next_invoice(
        self, org_a, account, admin_profile, clock
    ):
        project = make_retainer(
            org_a,
            account,
            retainer_hours=Decimal("1"),
            retainer_overage_rate=Decimal("100"),
        )
        timer = log_at(project, admin_profile, at(2026, 10, 31, 23), 0, running=True)

        clock.set(2026, 11, 1, 0, 20)
        run_job()
        october = Invoice.objects.get()
        assert billed(october) == set()
        assert lines(october) == [FEE]

        timer.ended_at = at(2026, 11, 1, 2)
        timer.save()
        clock.set(2026, 12, 1, 0, 20)
        run_job()
        november = Invoice.objects.exclude(pk=october.pk).get()
        assert billed(november) == {timer.id}
        assert lines(november) == [
            ("November 2026 retainer", Decimal("1.00"), Decimal("1000.00")),
            ("Hours over the allowance", Decimal("2.00"), Decimal("100.00")),
        ]


@pytest.mark.django_db
class TestUsage:
    def usage(self, client, project):
        response = client.get(f"/api/projects/{project.id}/")
        assert response.status_code == 200
        return response.json()["retainer_usage"]

    def test_null_unless_a_retainer(self, admin_client, org_a, account):
        project = make_project(org_a, account, retainer_fee=Decimal("10"))

        assert self.usage(admin_client, project) is None

    def test_what_billing_the_next_month_would_count_today(
        self,
        admin_client,
        user_client,
        org_a,
        account,
        admin_profile,
        clock,
        admin_user,
        user_profile,
    ):
        project = make_retainer(
            org_a,
            account,
            created_by=admin_user,
            assigned=[user_profile],
            retainer_hours=Decimal("10"),
            retainer_overage_rate=Decimal("100"),
            retainer_rollover=True,
            retainer_carried_hours=Decimal("2"),
        )
        log_at(project, admin_profile, at(2026, 9, 29, 9), 60)
        log_at(project, admin_profile, at(2026, 10, 2, 9), 12 * 60)
        log_at(project, admin_profile, at(2026, 10, 3, 9), 600, billable=False)

        expected = {
            "month": "2026-10",
            "used_hours": "13.00",
            "available_hours": "12.00",
            "overage_hours": "1.00",
            "billable_now": True,
        }
        assert self.usage(admin_client, project) == expected
        assert self.usage(user_client, project) == expected

    def test_without_an_allowance(
        self, admin_client, org_a, account, admin_profile, clock
    ):
        project = make_retainer(org_a, account)
        log_at(project, admin_profile, at(2026, 10, 2, 9), 90)

        assert self.usage(admin_client, project) == {
            "month": "2026-10",
            "used_hours": "1.50",
            "available_hours": None,
            "overage_hours": "0.00",
            "billable_now": True,
        }

    @pytest.mark.parametrize(
        "fields, off",
        [
            ({"retainer_next_month": NOVEMBER}, None),
            ({"retainer_last_month": SEPTEMBER}, None),
            ({}, "invoices"),
        ],
    )
    def test_not_billable_once_billed_ended_or_with_invoices_off(
        self, admin_client, org_a, account, clock, fields, off
    ):
        project = make_retainer(org_a, account, **fields)
        if off:
            set_modules_off(org_a, off)

        assert self.usage(admin_client, project)["billable_now"] is False


@pytest.mark.postgres_only
@pytest.mark.django_db(transaction=True)
def test_two_runs_at_once_draft_one_invoice(org_a, account):
    """Both start before either commits. The second waits on the project's row
    lock, then reads the month the first moved on, so it drafts nothing."""
    if connection.vendor != "postgresql":
        pytest.skip("row locks need PostgreSQL")

    from common.tasks import set_rls_context

    project = make_retainer(org_a, account)
    barrier = threading.Barrier(2)
    results, errors = [], []
    draft = retainers._draft

    def slow_draft(*args, **kwargs):
        invoice = draft(*args, **kwargs)
        time.sleep(0.5)
        return invoice

    def worker():
        try:
            set_rls_context(org_a.id)
            barrier.wait()
            results.append(bill_month(project.pk, org_a, NOVEMBER))
        except Exception as exc:  # recorded and asserted on below
            errors.append(exc)
        finally:
            connection.close()

    with mock.patch("projects.retainers._draft", slow_draft):
        threads = [threading.Thread(target=worker) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)

    assert errors == []
    assert sorted(result is None for result in results) == [False, True]
    set_rls_context(org_a.id)
    assert Invoice.objects.filter(project=project).count() == 1
    project.refresh_from_db()
    assert project.retainer_next_month == NOVEMBER
