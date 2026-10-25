"""Billing a project: time to a draft invoice with grouping, the unbilled
preview, an amount or a share of the fee, and cancelling frees the time."""

import datetime
from decimal import Decimal

import pytest
from django.contrib.admin.sites import site
from django.test import RequestFactory
from django.utils import timezone

from accounts.models import Account
from cases.models import Case, TimeEntry
from common.testing import set_modules_off
from conftest import rls_org
from contacts.models import Contact
from invoices.models import Invoice
from projects.tests.conftest import log_time, make_project
from tasks.models import Task

BILL = "/api/invoices/from-time-entries/"


@pytest.fixture
def project(org_a, account, admin_user, user_profile):
    return make_project(
        org_a,
        account,
        created_by=admin_user,
        assigned=[user_profile],
        currency="EUR",
        budget_amount=Decimal("2000"),
    )


def lines(invoice_id):
    invoice = Invoice.objects.get(pk=invoice_id)
    return [
        (line.name, line.quantity, line.unit_price)
        for line in invoice.line_items.order_by("order")
    ]


@pytest.mark.django_db
class TestBillAProject:
    def test_bills_every_unbilled_entry_up_to_the_date(
        self, admin_client, project, account, admin_profile, user_profile, org_a
    ):
        contact = Contact.objects.create(first_name="Ana", last_name="R", org=org_a)
        account.contacts.add(contact)
        old = log_time(project, admin_profile, 60, days_ago=10)
        recent = log_time(project, user_profile, 30, days_ago=1)
        log_time(project, admin_profile, 30, billable=False)
        up_to = (timezone.localdate() - datetime.timedelta(days=5)).isoformat()

        response = admin_client.post(
            BILL, {"project_id": str(project.id), "up_to": up_to}, format="json"
        )

        assert response.status_code == 201, response.json()
        body = response.json()
        assert body["project_id"] == str(project.id)
        assert body["entry_ids"] == [str(old.id)]
        invoice = Invoice.objects.get(pk=body["invoice_id"])
        assert (invoice.project_id, invoice.account_id, invoice.currency) == (
            project.id,
            account.id,
            "EUR",
        )
        assert (invoice.status, invoice.contact_id) == ("Draft", contact.id)
        old.refresh_from_db()
        recent.refresh_from_db()
        assert (old.invoice_id, recent.invoice_id) == (invoice.id, None)

        again = admin_client.post(BILL, {"project_id": str(project.id)}, format="json")
        assert again.status_code == 201
        assert again.json()["entry_ids"] == [str(recent.id)]

    def test_a_billed_entry_is_never_billed_twice(
        self, admin_client, project, admin_profile
    ):
        entry = log_time(project, admin_profile, 60)
        first = admin_client.post(BILL, {"project_id": str(project.id)}, format="json")

        by_id = admin_client.post(
            BILL,
            {"project_id": str(project.id), "entry_ids": [str(entry.id)]},
            format="json",
        )
        by_date = admin_client.post(
            BILL, {"project_id": str(project.id)}, format="json"
        )

        assert first.status_code == 201
        assert by_id.status_code == 400
        assert "already been invoiced" in by_id.json()["message"]
        assert by_date.status_code == 400
        assert Invoice.objects.count() == 1

    def test_named_entries_must_be_on_the_project(
        self, admin_client, org_a, project, account, admin_profile
    ):
        other = make_project(org_a, account, name="Other", currency="EUR")
        stranger = log_time(other, admin_profile, 30)

        response = admin_client.post(
            BILL,
            {"project_id": str(project.id), "entry_ids": [str(stranger.id)]},
            format="json",
        )

        assert response.status_code == 400
        assert "not on this project" in response.json()["message"]
        assert not Invoice.objects.exists()

    def test_a_member_gets_403_and_another_org_404(
        self, user_client, admin_client, project, admin_profile, org_b
    ):
        log_time(project, admin_profile, 60)
        with rls_org(org_b):
            theirs = make_project(org_b, Account.objects.create(name="B", org=org_b))

        member = user_client.post(BILL, {"project_id": str(project.id)}, format="json")
        foreign = admin_client.post(BILL, {"project_id": str(theirs.id)}, format="json")

        assert member.status_code == 403
        assert foreign.status_code == 404
        assert not Invoice.objects.exists()

    @pytest.mark.parametrize(
        "body",
        [
            {},
            {"project_id": "x"},
            {"project_id": "PID", "account_id": "AID"},
            {"project_id": "PID", "group_by": "day"},
            {"project_id": "PID", "up_to": "yesterday"},
        ],
    )
    def test_bad_bodies_are_400s(self, admin_client, project, account, body):
        body = {
            k: {"PID": str(project.id), "AID": str(account.id)}.get(v, v)
            for k, v in body.items()
        }

        assert admin_client.post(BILL, body, format="json").status_code == 400

    def test_nothing_to_bill_is_a_400(self, admin_client, project):
        response = admin_client.post(
            BILL, {"project_id": str(project.id)}, format="json"
        )

        assert response.status_code == 400
        assert not Invoice.objects.exists()


@pytest.mark.django_db
class TestGrouping:
    @pytest.fixture
    def entries(self, org_a, project, admin_profile, user_profile):
        design = Task.objects.create(
            title="Design", status="New", priority="Low", org=org_a, project=project
        )
        return [
            log_time(project, admin_profile, 60, rate="100", task=design, days_ago=3),
            log_time(project, admin_profile, 30, rate="100", days_ago=2),
            log_time(project, admin_profile, 30, rate="150", task=design, days_ago=2),
            log_time(project, user_profile, 90, rate="80", days_ago=1),
        ]

    def bill(self, client, project, group_by):
        response = client.post(
            BILL, {"project_id": str(project.id), "group_by": group_by}, format="json"
        )
        assert response.status_code == 201, response.json()
        return lines(response.json()["invoice_id"])

    def test_by_entry(self, admin_client, project, entries):
        assert [line[1:] for line in self.bill(admin_client, project, "entry")] == [
            (Decimal("1.00"), Decimal("100.00")),
            (Decimal("0.50"), Decimal("100.00")),
            (Decimal("0.50"), Decimal("150.00")),
            (Decimal("1.50"), Decimal("80.00")),
        ]

    def test_by_person_splits_rates(self, admin_client, project, entries):
        assert self.bill(admin_client, project, "person") == [
            ("admin", Decimal("1.50"), Decimal("100.00")),
            ("admin", Decimal("0.50"), Decimal("150.00")),
            ("user", Decimal("1.50"), Decimal("80.00")),
        ]

    def test_by_task_puts_untasked_time_on_one_line(
        self, admin_client, project, entries
    ):
        assert self.bill(admin_client, project, "task") == [
            ("Design", Decimal("1.00"), Decimal("100.00")),
            ("Other time", Decimal("0.50"), Decimal("100.00")),
            ("Design", Decimal("0.50"), Decimal("150.00")),
            ("Other time", Decimal("1.50"), Decimal("80.00")),
        ]

    def test_single(self, admin_client, project, entries):
        assert self.bill(admin_client, project, "single") == [
            ("Site build", Decimal("1.50"), Decimal("100.00")),
            ("Site build", Decimal("0.50"), Decimal("150.00")),
            ("Site build", Decimal("1.50"), Decimal("80.00")),
        ]

    def test_ticket_time_groups_too(self, admin_client, org_a, account, admin_profile):
        case = Case.objects.create(
            name="Fix", status="New", priority="Normal", org=org_a, account=account
        )
        ids = []
        for minutes in (30, 45):
            end = timezone.now() - datetime.timedelta(hours=1)
            ids.append(
                str(
                    TimeEntry.objects.create(
                        org=org_a,
                        case=case,
                        profile=admin_profile,
                        started_at=end - datetime.timedelta(minutes=minutes),
                        ended_at=end,
                        billable=True,
                        hourly_rate=Decimal("60"),
                    ).id
                )
            )

        response = admin_client.post(
            BILL,
            {"account_id": str(account.id), "entry_ids": ids, "group_by": "single"},
            format="json",
        )

        assert response.status_code == 201
        assert response.json()["project_id"] is None
        assert lines(response.json()["invoice_id"]) == [
            ("Time", Decimal("1.25"), Decimal("60.00"))
        ]

    def test_account_mode_refuses_project_and_parentless_time(
        self, admin_client, project, account, admin_profile
    ):
        on_project = log_time(project, admin_profile, 30)
        orphan = log_time(project, admin_profile, 30)
        TimeEntry.objects.filter(pk=orphan.pk).update(project=None)

        for entry in (on_project, orphan):
            response = admin_client.post(
                BILL,
                {"account_id": str(account.id), "entry_ids": [str(entry.id)]},
                format="json",
            )
            assert response.status_code == 400
            assert "not on a ticket" in response.json()["message"]
        assert not Invoice.objects.exists()

    def test_a_parentless_entry_is_never_picked_up_by_a_project(
        self, admin_client, project, admin_profile
    ):
        orphan = log_time(project, admin_profile, 30)
        TimeEntry.objects.filter(pk=orphan.pk).update(project=None)

        by_date = admin_client.post(
            BILL, {"project_id": str(project.id)}, format="json"
        )
        by_id = admin_client.post(
            BILL,
            {"project_id": str(project.id), "entry_ids": [str(orphan.id)]},
            format="json",
        )

        assert by_date.status_code == 400
        assert by_id.status_code == 400
        assert not Invoice.objects.exists()


@pytest.mark.django_db
class TestUnbilled:
    def test_the_preview_matches_the_bill(
        self, admin_client, project, admin_profile, user_profile
    ):
        log_time(project, admin_profile, 90, rate="100", days_ago=3)
        log_time(project, user_profile, 30, rate=None, days_ago=3)
        log_time(project, user_profile, 60, rate="100")
        up_to = (timezone.localdate() - datetime.timedelta(days=1)).isoformat()

        body = admin_client.get(
            f"/api/projects/{project.id}/unbilled/", {"up_to": up_to}
        ).json()

        assert body == {
            "entry_count": 2,
            "hours": "2.00",
            "value": "150.00",
            "currency": "EUR",
            "unrated_count": 1,
        }

    def test_who_may_preview(
        self, user_client, admin_client, project, org_b, org_b_client
    ):
        url = f"/api/projects/{project.id}/unbilled/"

        assert user_client.get(url).status_code == 403
        assert admin_client.get(url).status_code == 200
        assert org_b_client.get(url).status_code == 404
        assert admin_client.get(url, {"up_to": "nope"}).status_code == 400


@pytest.mark.django_db
class TestInvoiceAnAmount:
    def url(self, project):
        return f"/api/projects/{project.id}/invoice-amount/"

    def test_an_amount(self, admin_client, project, account):
        response = admin_client.post(
            self.url(project), {"amount": "750"}, format="json"
        )

        assert response.status_code == 201
        invoice = Invoice.objects.get(pk=response.json()["invoice_id"])
        assert response.json()["invoice_number"] == invoice.invoice_number
        assert (invoice.status, invoice.project_id, invoice.account_id) == (
            "Draft",
            project.id,
            account.id,
        )
        assert (invoice.currency, invoice.total_amount) == ("EUR", Decimal("750.00"))
        assert lines(invoice.id) == [
            ("Site build, fixed fee", Decimal("1.00"), Decimal("750.00"))
        ]

    def test_a_percent_of_the_fee_with_a_description(self, admin_client, project):
        response = admin_client.post(
            self.url(project),
            {"percent": "25", "description": "Deposit"},
            format="json",
        )

        assert response.status_code == 201
        assert lines(response.json()["invoice_id"]) == [
            ("Deposit", Decimal("1.00"), Decimal("500.00"))
        ]
        detail = admin_client.get(f"/api/projects/{project.id}/").json()
        assert detail["burn"]["invoiced_amount"] == "500.00"
        assert [i["id"] for i in detail["invoices"]] == [response.json()["invoice_id"]]

    @pytest.mark.parametrize(
        "body",
        [
            {},
            {"amount": "10", "percent": "10"},
            {"amount": "0"},
            {"amount": "-1"},
            {"percent": "0"},
            {"percent": "101"},
            {"amount": "abc"},
        ],
    )
    def test_bad_bodies(self, admin_client, project, body):
        response = admin_client.post(self.url(project), body, format="json")

        assert response.status_code == 400
        assert response.json()["error"] is True
        assert not Invoice.objects.exists()

    def test_a_percent_needs_a_budget(self, admin_client, org_a, account):
        project = make_project(org_a, account)

        response = admin_client.post(
            self.url(project), {"percent": "50"}, format="json"
        )

        assert response.status_code == 400
        assert "percent" in response.json()["errors"]

    def test_who_may(self, user_client, org_b_client, admin_client, project):
        assert user_client.post(self.url(project), {"amount": "5"}).status_code == 403
        assert org_b_client.post(self.url(project), {"amount": "5"}).status_code == 404
        assert admin_client.post(self.url(project), {"amount": "5"}).status_code == 201


@pytest.mark.django_db
class TestCancelFreesTime:
    @pytest.fixture
    def billed(self, admin_client, project, admin_profile):
        entry = log_time(project, admin_profile, 60)
        body = admin_client.post(BILL, {"project_id": str(project.id)}, format="json")
        entry.refresh_from_db()
        assert entry.invoice_id is not None
        return Invoice.objects.get(pk=body.json()["invoice_id"]), entry

    def test_the_cancel_endpoint(self, admin_client, project, billed):
        invoice, entry = billed

        response = admin_client.post(f"/api/invoices/{invoice.id}/cancel/")

        assert response.status_code == 200
        entry.refresh_from_db()
        assert entry.invoice_id is None
        again = admin_client.post(BILL, {"project_id": str(project.id)}, format="json")
        assert again.status_code == 201
        detail = admin_client.get(f"/api/projects/{project.id}/").json()
        assert detail["burn"]["invoiced_amount"] == "100.00"

    def test_a_model_save(self, billed):
        invoice, entry = billed
        invoice.status = "Cancelled"
        invoice.save(update_fields=["status"])

        entry.refresh_from_db()
        assert entry.invoice_id is None

    def test_the_django_admin_change_form(self, billed, admin_user):
        invoice, entry = billed
        model_admin = site._registry[Invoice]
        request = RequestFactory().post("/")
        request.user = admin_user
        invoice.status = "Cancelled"

        model_admin.save_model(request, invoice, form=None, change=True)

        entry.refresh_from_db()
        assert entry.invoice_id is None

    def test_an_invoice_with_a_payment_keeps_its_time_when_cancelled(
        self, admin_client, billed
    ):
        invoice, entry = billed
        paid = admin_client.post(
            f"/api/invoices/{invoice.id}/mark-paid/", {"amount": "40"}, format="json"
        )
        invoice.refresh_from_db()
        assert paid.status_code in (200, 201), paid.json()
        assert invoice.status == "Partially_Paid"

        response = admin_client.post(f"/api/invoices/{invoice.id}/cancel/")

        assert response.status_code == 200
        invoice.refresh_from_db()
        entry.refresh_from_db()
        assert invoice.status == "Cancelled"
        assert entry.invoice_id == invoice.id

    def test_other_statuses_keep_the_link(self, billed):
        invoice, entry = billed
        for state in ("Sent", "Paid", "Overdue"):
            invoice.status = state
            invoice.save()
            entry.refresh_from_db()
            assert entry.invoice_id == invoice.id

    def test_an_invoice_read_carries_its_project(self, admin_client, project, billed):
        invoice, _ = billed

        detail = admin_client.get(f"/api/invoices/{invoice.id}/").json()
        listing = admin_client.get("/api/invoices/").json()

        assert detail["invoice"]["project"] == str(project.id)
        assert listing["results"][0]["project"] == str(project.id)


@pytest.mark.django_db
class TestModulesOff:
    def test_billing_a_project_needs_projects_and_a_ticket_account_tickets(
        self, admin_client, org_a, project, account, admin_profile
    ):
        log_time(project, admin_profile, 30)
        set_modules_off(org_a, "projects")
        response = admin_client.post(
            BILL, {"project_id": str(project.id)}, format="json"
        )
        assert response.status_code == 404
        assert response.json()["module"] == "projects"

        set_modules_off(org_a, "tickets")
        ticket = admin_client.post(
            BILL, {"account_id": str(account.id), "entry_ids": []}, format="json"
        )
        assert ticket.status_code == 404
        assert ticket.json()["module"] == "tickets"
        on = admin_client.post(BILL, {"project_id": str(project.id)}, format="json")
        assert on.status_code == 201

    @pytest.mark.parametrize(
        "off, path",
        [
            ("projects", ""),
            ("projects", "time-entries/"),
            ("timesheet", "time-entries/"),
            ("invoices", "unbilled/"),
            ("invoices", "invoice-amount/"),
        ],
    )
    def test_project_routes_answer_like_other_modules(
        self, admin_client, org_a, project, off, path
    ):
        set_modules_off(org_a, off)

        response = admin_client.get(f"/api/projects/{project.id}/{path}")

        assert response.status_code == 404
        assert response.json()["code"] == "module_off"
        assert response.json()["module"] == off

    def test_invoices_off_empties_the_detail_invoices(
        self, admin_client, org_a, project, account
    ):
        Invoice.objects.create(
            invoice_title="X", account=account, org=org_a, project=project
        )
        assert (
            len(admin_client.get(f"/api/projects/{project.id}/").json()["invoices"])
            == 1
        )

        set_modules_off(org_a, "invoices")

        assert admin_client.get(f"/api/projects/{project.id}/").json()["invoices"] == []
