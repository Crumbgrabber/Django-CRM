"""The proposal on the estimate PDF, raising the full invoice after a deposit,
and the project page naming the estimate that started it."""

from decimal import Decimal
from unittest import mock

import pytest
from rest_framework.test import APIClient

from accounts.models import Account
from common.models import Notification, Profile, User
from common.testing import _make_authenticated_client, set_modules_off
from invoices import pdf
from invoices.models import Estimate, EstimateLineItem, Invoice
from projects.models import Project


@pytest.fixture
def account(org_a):
    return Account.objects.create(name="Northwind", org=org_a)


def _estimate(org, account, creator=None, **fields):
    estimate = Estimate.objects.create(
        org=org,
        account=account,
        title="Brand sprint",
        currency="USD",
        tax_rate=Decimal("10"),
        created_by=creator,
        **fields,
    )
    EstimateLineItem.objects.create(
        estimate=estimate, org=org, description="Work", unit_price=Decimal("1000")
    )
    estimate.save()
    estimate.refresh_from_db()
    return estimate


def _accepted(estimate):
    Estimate.objects.filter(pk=estimate.pk).update(status="Sent")
    res = APIClient().post(
        f"/api/public/estimate/{estimate.public_token}/accept/",
        {"name": "Nora", "email": "nora@client.example"},
        format="json",
    )
    assert res.status_code == 200
    estimate.refresh_from_db()
    return estimate


def _html(estimate):
    with (
        mock.patch.object(pdf, "check_weasyprint"),
        mock.patch.object(pdf, "_write_pdf", return_value=b"%PDF-") as write,
    ):
        assert pdf.generate_estimate_pdf(estimate) == b"%PDF-"
    return write.call_args.args[0]


class TestPdf:
    def test_the_introduction_sits_above_the_lines_escaped(self, org_a, account):
        estimate = _estimate(
            org_a, account, introduction="Dear Nora,\n<script>x()</script>\nThanks"
        )
        html = _html(estimate)
        assert "Dear Nora,<br>&lt;script&gt;x()&lt;/script&gt;<br>Thanks" in html
        assert "<script>" not in html
        assert html.index("Dear Nora") < html.index('class="line-items"')

    def test_a_deposit_line_under_the_totals(self, org_a, account):
        html = _html(_estimate(org_a, account, deposit_percent=Decimal("50")))
        assert "Deposit on acceptance (50%)" in html
        assert "$550.00" in html
        assert html.index("grand-total") < html.index("Deposit on acceptance")

    def test_neither_when_there_is_none(self, org_a, account):
        html = _html(_estimate(org_a, account))
        assert "Deposit on acceptance" not in html
        assert "introduction" not in html


class TestConvert:
    def _convert(self, client, estimate):
        return client.post(f"/api/invoices/estimates/{estimate.id}/convert/")

    def test_the_invoice_takes_the_project_and_names_the_deposit(
        self, admin_client, org_a, account, admin_user
    ):
        estimate = _accepted(
            _estimate(
                org_a,
                account,
                admin_user,
                start_project=True,
                deposit_percent=Decimal("50"),
            )
        )
        res = self._convert(admin_client, estimate)
        assert res.status_code == 201
        body = res.json()
        invoice = Invoice.objects.get(pk=body["invoice"]["id"])
        assert invoice.project_id == estimate.project_id
        assert body["invoice"]["project"] == str(estimate.project_id)
        deposit = estimate.deposit_invoice
        assert body["deposit_invoice"] == {
            "id": str(deposit.id),
            "invoice_number": deposit.invoice_number,
            "status": "Draft",
            "total_amount": "550.00",
        }
        # The full invoice bills every line; the deposit is not taken off.
        assert invoice.total_amount == Decimal("1100.00")
        estimate.refresh_from_db()
        assert estimate.converted_to_invoice == invoice
        assert estimate.deposit_invoice == deposit

    def test_a_cancelled_deposit_is_not_named(
        self, admin_client, org_a, account, admin_user
    ):
        estimate = _accepted(
            _estimate(org_a, account, admin_user, deposit_percent=Decimal("50"))
        )
        Invoice.objects.filter(pk=estimate.deposit_invoice_id).update(
            status="Cancelled"
        )
        body = self._convert(admin_client, estimate).json()
        assert body["deposit_invoice"] is None

    def test_without_a_proposal(self, admin_client, org_a, account):
        body = self._convert(admin_client, _estimate(org_a, account)).json()
        assert body["deposit_invoice"] is None
        assert body["invoice"]["project"] is None
        assert not Project.objects.exists()

    def test_raising_before_acceptance_starts_the_project(
        self, admin_client, org_a, account, admin_user, admin_profile, user_profile
    ):
        estimate = _estimate(
            org_a,
            account,
            admin_user,
            start_project=True,
            project_billing_type="time_and_materials",
            deposit_percent=Decimal("50"),
        )
        estimate.assigned_to.add(user_profile)
        Estimate.objects.filter(pk=estimate.pk).update(status="Sent")

        res = self._convert(admin_client, estimate)

        assert res.status_code == 201
        body = res.json()
        project = Project.objects.get()
        assert project.org_id == org_a.id
        assert (project.name, project.account, project.billing_type) == (
            "Brand sprint",
            account,
            "time_and_materials",
        )
        assert project.budget_amount == Decimal("1000.00")
        assert project.created_by == admin_user
        assert set(project.assigned_to.all()) == {user_profile, admin_profile}
        # The full invoice only: no deposit is drafted.
        invoice = Invoice.objects.get()
        assert str(invoice.pk) == body["invoice"]["id"]
        assert invoice.project == project
        assert body["invoice"]["project"] == str(project.id)
        assert body["deposit_invoice"] is None
        estimate.refresh_from_db()
        assert estimate.project == project
        assert estimate.deposit_invoice is None
        assert estimate.converted_to_invoice == invoice
        assert not Notification.objects.exists()

    def test_raising_after_acceptance_reuses_its_project(
        self, admin_client, org_a, account, admin_user
    ):
        estimate = _accepted(_estimate(org_a, account, admin_user, start_project=True))
        started = estimate.project
        res = self._convert(admin_client, estimate)
        assert res.status_code == 201
        assert Project.objects.get() == started
        assert res.json()["invoice"]["project"] == str(started.id)
        estimate.refresh_from_db()
        assert estimate.project == started

    def test_no_project_while_projects_is_off(
        self, admin_client, org_a, account, admin_user
    ):
        estimate = _estimate(org_a, account, admin_user, start_project=True)
        set_modules_off(org_a, "projects")
        res = self._convert(admin_client, estimate)
        assert res.status_code == 201
        assert res.json()["invoice"]["project"] is None
        assert not Project.objects.exists()
        estimate.refresh_from_db()
        assert estimate.project is None

    def test_a_refused_second_convert_starts_nothing(
        self, admin_client, org_a, account, admin_user
    ):
        estimate = _estimate(org_a, account, admin_user, start_project=True)
        assert self._convert(admin_client, estimate).status_code == 201
        Project.objects.all().delete()
        assert self._convert(admin_client, estimate).status_code == 400
        assert not Project.objects.exists()


class TestProjectNamesItsEstimate:
    def test_the_project_detail_carries_the_estimate(
        self, admin_client, org_a, account, admin_user
    ):
        estimate = _accepted(_estimate(org_a, account, admin_user, start_project=True))
        body = admin_client.get(f"/api/projects/{estimate.project_id}/").json()
        assert body["estimate"] == {
            "id": str(estimate.id),
            "estimate_number": estimate.estimate_number,
        }

    def test_a_project_not_from_an_estimate(self, admin_client, org_a, account):
        project = Project.objects.create(org=org_a, name="Direct", account=account)
        body = admin_client.get(f"/api/projects/{project.id}/").json()
        assert body["estimate"] is None

    def test_hidden_from_a_project_member_who_cannot_open_the_estimate(
        self, org_a, account, admin_user
    ):
        estimate = _accepted(_estimate(org_a, account, admin_user, start_project=True))
        user = User.objects.create_user(email="member@test.com", password="pw")
        member = Profile.objects.create(user=user, org=org_a, role="USER")
        estimate.project.assigned_to.add(member)
        client = _make_authenticated_client(user, org_a, member)
        body = client.get(f"/api/projects/{estimate.project_id}/").json()
        assert body["estimate"] is None
        estimate.assigned_to.add(member)
        body = client.get(f"/api/projects/{estimate.project_id}/").json()
        assert body["estimate"]["id"] == str(estimate.id)

    def test_hidden_while_invoices_is_off(
        self, admin_client, org_a, account, admin_user
    ):
        estimate = _accepted(_estimate(org_a, account, admin_user, start_project=True))
        set_modules_off(org_a, "invoices")
        body = admin_client.get(f"/api/projects/{estimate.project_id}/").json()
        assert body["estimate"] is None
