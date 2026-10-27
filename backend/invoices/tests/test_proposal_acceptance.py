"""What a client's acceptance of a proposal starts: the project, the draft
deposit invoice, the links on the estimate and the notifications. Declining
notifies too. All of it is anonymous, so the org comes only from the token."""

import datetime
from decimal import Decimal

import pytest
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Account
from common.models import Notification, Org, Profile, Teams, User
from common.testing import _make_authenticated_client, set_modules_off
from contacts.models import Contact
from invoices.models import Estimate, EstimateLineItem, Invoice
from invoices.permissions import visible_invoices_qs
from opportunity.models import Opportunity
from projects.access import visible_projects_qs
from projects.models import Project, ProjectRate

ACCEPTOR = {"name": "Nora Fitz", "email": "nora@client.example"}


def _member(org, email, role="USER", active=True):
    user = User.objects.create_user(email=email, password="pw-not-used")
    return Profile.objects.create(user=user, org=org, role=role, is_active=active)


@pytest.fixture
def creator(user_profile):
    return user_profile


@pytest.fixture
def assignee(org_a):
    return _member(org_a, "assignee@test.com")


@pytest.fixture
def outsider(org_a):
    return _member(org_a, "outsider@test.com")


@pytest.fixture
def account(org_a, admin_user):
    return Account.objects.create(name="Northwind", org=org_a, created_by=admin_user)


@pytest.fixture
def contact(org_a, account):
    return Contact.objects.create(
        first_name="Nora", last_name="Fitz", org=org_a, account=account
    )


@pytest.fixture
def deal(org_a, account):
    return Opportunity.objects.create(name="Brand refresh", org=org_a, account=account)


def _proposal(org, account, contact, deal, creator, assignees=(), **fields):
    """A Sent estimate: 1000 of lines, 10% off, 10% tax, so 900 pre-tax."""
    values = {
        "title": "Brand sprint",
        "currency": "EUR",
        "tax_rate": Decimal("10"),
        "discount_type": "PERCENTAGE",
        "discount_value": Decimal("10"),
        "client_name": "Northwind Ltd",
        "client_email": "billing@northwind.example",
        "client_city": "Leeds",
        "expiry_date": timezone.localdate() + datetime.timedelta(days=30),
        **fields,
    }
    estimate = Estimate.objects.create(
        org=org,
        account=account,
        contact=contact,
        opportunity=deal,
        created_by=creator.user if creator else None,
        **values,
    )
    for price in ("600.00", "400.00"):
        EstimateLineItem.objects.create(
            estimate=estimate, org=org, description="Work", unit_price=Decimal(price)
        )
    estimate.save()
    estimate.assigned_to.set(assignees)
    Estimate.objects.filter(pk=estimate.pk).update(status="Sent")
    estimate.refresh_from_db()
    return estimate


@pytest.fixture
def make(org_a, account, contact, deal, creator, assignee):
    def build(**fields):
        return _proposal(org_a, account, contact, deal, creator, [assignee], **fields)

    return build


def _accept(token, data=ACCEPTOR, client=None):
    client = client or APIClient()
    return client.post(f"/api/public/estimate/{token}/accept/", data, format="json")


def _public(token):
    return APIClient().get(f"/api/public/estimate/{token}/")


def _notes(verb="estimate.accepted"):
    return list(Notification.objects.filter(verb=verb).order_by("recipient_id"))


class TestCombinations:
    def test_neither(self, make):
        estimate = make()
        assert _accept(estimate.public_token).status_code == 200
        estimate.refresh_from_db()
        assert estimate.status == "Accepted"
        assert (estimate.project, estimate.deposit_invoice) == (None, None)
        assert not Project.objects.exists() and not Invoice.objects.exists()
        note = _notes()[0]
        assert note.link == "/invoices/estimates"
        assert note.data == {
            "estimate_number": estimate.estimate_number,
            "client_name": "Nora Fitz",
            "project_id": None,
            "deposit_invoice_id": None,
        }

    def test_project_only(self, make, account, deal, creator, assignee):
        estimate = make(start_project=True, project_billing_type="time_and_materials")
        assert _accept(estimate.public_token).status_code == 200
        estimate.refresh_from_db()
        project = estimate.project
        assert project is not None and estimate.deposit_invoice is None
        assert project.org_id == estimate.org_id
        assert project.name == "Brand sprint"
        assert (project.account, project.deal, project.currency) == (
            account,
            deal,
            "EUR",
        )
        assert project.billing_type == "time_and_materials"
        assert project.budget_amount == Decimal("900.00")
        assert project.status == "active"
        assert project.start_date == timezone.localdate()
        assert project.created_by == creator.user
        assert set(project.assigned_to.all()) == {creator, assignee}
        assert project.hourly_rate is None
        assert not ProjectRate.objects.exists()
        assert not Invoice.objects.exists()
        assert {n.link for n in _notes()} == {f"/projects/{project.id}"}
        assert _notes()[0].data["project_id"] == str(project.id)

    def test_deposit_only(self, make, account, contact, deal, creator, assignee):
        team = Teams.objects.create(name="Studio", description="", org=account.org)
        estimate = make(deposit_percent=Decimal("50"))
        estimate.teams.add(team)
        shown = _public(estimate.public_token).json()["deposit"]
        assert _accept(estimate.public_token).status_code == 200
        estimate.refresh_from_db()
        invoice = estimate.deposit_invoice
        assert invoice is not None and estimate.project is None
        assert invoice.org_id == estimate.org_id
        assert invoice.status == "Draft"
        assert (invoice.account, invoice.contact, invoice.opportunity) == (
            account,
            contact,
            deal,
        )
        assert (invoice.client_name, invoice.client_email, invoice.client_city) == (
            "Northwind Ltd",
            "billing@northwind.example",
            "Leeds",
        )
        assert invoice.currency == "EUR" and invoice.project is None
        line = invoice.line_items.get()
        assert line.quantity == 1
        assert line.unit_price == Decimal("450.00")
        assert (
            line.name
            == line.description
            == (f"Deposit: 50% of estimate {estimate.estimate_number}, Brand sprint")
        )
        assert invoice.tax_rate == line.tax_rate == Decimal("10")
        assert invoice.total_amount == Decimal("495.00")
        assert shown == {"percent": "50.00", "amount": "495.00", "currency": "EUR"}
        assert str(invoice.total_amount) == shown["amount"]
        assert invoice.issue_date == timezone.localdate()
        assert invoice.due_date == timezone.localdate() + datetime.timedelta(days=30)
        assert invoice.created_by == creator.user
        assert set(invoice.assigned_to.all()) == {assignee}
        assert set(invoice.teams.all()) == {team}
        assert invoice.sent_at is None and not invoice.is_email_sent
        assert estimate.converted_to_invoice is None
        assert {n.link for n in _notes()} == {f"/invoices/{invoice.id}"}

    def test_both(self, make):
        estimate = make(start_project=True, deposit_percent=Decimal("20"))
        shown = _public(estimate.public_token).json()["deposit"]
        assert _accept(estimate.public_token).status_code == 200
        estimate.refresh_from_db()
        assert estimate.deposit_invoice.project == estimate.project
        assert estimate.project.billing_type == "fixed_fee"
        assert str(estimate.deposit_invoice.total_amount) == shown["amount"] == "198.00"
        note = _notes()[0]
        assert note.link == f"/projects/{estimate.project_id}"
        assert note.data["deposit_invoice_id"] == str(estimate.deposit_invoice_id)

    def test_projects_module_off(self, make, org_a):
        estimate = make(start_project=True, deposit_percent=Decimal("20"))
        set_modules_off(org_a, "projects")
        assert _accept(estimate.public_token).status_code == 200
        estimate.refresh_from_db()
        assert estimate.project is None and not Project.objects.exists()
        assert estimate.deposit_invoice is not None
        assert estimate.deposit_invoice.project is None

    def test_a_non_billable_project_has_no_budget(self, make):
        estimate = make(start_project=True, project_billing_type="non_billable")
        _accept(estimate.public_token)
        estimate.refresh_from_db()
        assert estimate.project.billing_type == "non_billable"
        assert estimate.project.budget_amount is None

    def test_an_untitled_estimate_names_the_project_by_account(self, make):
        estimate = make(start_project=True, title="")
        _accept(estimate.public_token)
        estimate.refresh_from_db()
        assert estimate.project.name == (
            f"Northwind, estimate {estimate.estimate_number}"
        )
        assert estimate.project.deal is not None

    @pytest.mark.parametrize(
        "fields",
        [
            # 0.01% of the 0.10 left after 99.99% off is 0.00001.
            {"discount_value": Decimal("99.99"), "deposit_percent": Decimal("0.01")},
            # A flat discount equal to the subtotal.
            {
                "discount_type": "FIXED",
                "discount_value": Decimal("1000"),
                "deposit_percent": Decimal("50"),
            },
        ],
    )
    def test_a_deposit_totalling_nothing_drafts_no_invoice(self, make, fields):
        estimate = make(start_project=True, **fields)
        assert _public(estimate.public_token).json()["deposit"] is None
        assert _accept(estimate.public_token).status_code == 200
        estimate.refresh_from_db()
        assert estimate.status == "Accepted"
        assert estimate.deposit_invoice is None and not Invoice.objects.exists()
        assert estimate.project is not None
        note = _notes()[0]
        assert note.link == f"/projects/{estimate.project_id}"
        assert note.data["deposit_invoice_id"] is None

    def test_with_nothing_else_the_note_links_the_estimates(self, make):
        estimate = make(
            discount_type="FIXED",
            discount_value=Decimal("1000"),
            deposit_percent=Decimal("50"),
        )
        _accept(estimate.public_token)
        assert not Invoice.objects.exists()
        assert {n.link for n in _notes()} == {"/invoices/estimates"}

    def test_a_deposit_on_an_untitled_estimate(self, make):
        estimate = make(title="", deposit_percent=Decimal("12.5"))
        _accept(estimate.public_token)
        estimate.refresh_from_db()
        assert estimate.deposit_invoice.line_items.get().description == (
            f"Deposit: 12.5% of estimate {estimate.estimate_number}"
        )


class TestOnce:
    def test_a_second_accept_creates_nothing(self, make):
        estimate = make(start_project=True, deposit_percent=Decimal("50"))
        assert _accept(estimate.public_token).status_code == 200
        counts = (
            Project.objects.count(),
            Invoice.objects.count(),
            Notification.objects.count(),
        )
        again = _accept(estimate.public_token)
        assert again.status_code == 400
        assert (
            (
                Project.objects.count(),
                Invoice.objects.count(),
                Notification.objects.count(),
            )
            == counts
            == (1, 1, 2)
        )

    def test_a_failure_rolls_the_whole_accept_back(self, make, monkeypatch):
        estimate = make(start_project=True, deposit_percent=Decimal("50"))

        def broken(*args, **kwargs):
            raise RuntimeError("deposit failed")

        monkeypatch.setattr("invoices.proposals._draft_deposit_invoice", broken)
        res = _accept(
            estimate.public_token, client=APIClient(raise_request_exception=False)
        )
        assert res.status_code == 500
        estimate.refresh_from_db()
        assert estimate.status == "Sent"
        assert estimate.accepted_at is None and estimate.accepted_by_name == ""
        assert (estimate.project, estimate.deposit_invoice) == (None, None)
        assert not Project.objects.exists()
        assert not Invoice.objects.exists()
        assert not Notification.objects.exists()

        monkeypatch.undo()
        assert _accept(estimate.public_token).status_code == 200
        assert Project.objects.count() == 1 and Invoice.objects.count() == 1

    def test_converting_stays_available_after_a_deposit(self, make, admin_client):
        estimate = make(deposit_percent=Decimal("50"))
        _accept(estimate.public_token)
        res = admin_client.post(f"/api/invoices/estimates/{estimate.id}/convert/")
        assert res.status_code == 201


class TestTheClientCannotSteer:
    def test_only_name_and_email_reach_the_records(self, make, org_b):
        other = Account.objects.create(name="Elsewhere", org=org_b)
        estimate = make(start_project=True, deposit_percent=Decimal("50"))
        res = _accept(
            estimate.public_token,
            {
                **ACCEPTOR,
                "org": str(org_b.id),
                "account": str(other.id),
                "account_id": str(other.id),
                "project_billing_type": "non_billable",
                "deposit_percent": "100",
                "budget_amount": "1",
                "title": "Planted",
                "currency": "USD",
                "assigned_to": [],
            },
        )
        assert res.status_code == 200
        estimate.refresh_from_db()
        project, invoice = estimate.project, estimate.deposit_invoice
        assert project.org_id == invoice.org_id == estimate.org_id
        assert project.account_id == invoice.account_id == estimate.account_id
        assert project.name == "Brand sprint"
        assert (project.billing_type, project.budget_amount) == (
            "fixed_fee",
            Decimal("900.00"),
        )
        assert invoice.currency == project.currency == "EUR"
        assert invoice.total_amount == Decimal("495.00")
        assert not Project.objects.filter(org=org_b).exists()
        assert not Invoice.objects.filter(org=org_b).exists()


class TestPublicPage:
    def test_the_page_shows_the_introduction_and_deposit(self, make):
        estimate = make(introduction="Dear Nora,\nOur plan.", deposit_percent=50)
        body = _public(estimate.public_token).json()
        assert body["introduction"] == "Dear Nora,\nOur plan."
        assert body["deposit"] == {
            "percent": "50.00",
            "amount": "495.00",
            "currency": "EUR",
        }

    def test_without_them(self, make):
        body = _public(make(start_project=True).public_token).json()
        assert (body["introduction"], body["deposit"]) == ("", None)
        assert not {"start_project", "project", "project_billing_type"} & set(body)


class TestWhoSeesWhatWasMade:
    def test_the_estimates_people_see_the_project_and_deposit(
        self, make, creator, assignee, outsider
    ):
        estimate = make(start_project=True, deposit_percent=Decimal("50"))
        _accept(estimate.public_token)
        estimate.refresh_from_db()
        project, invoice = estimate.project, estimate.deposit_invoice
        for person in (creator, assignee):
            assert visible_invoices_qs(person).filter(pk=invoice.pk).exists()
            assert visible_projects_qs(person).filter(pk=project.pk).exists()
            client = _make_authenticated_client(person.user, person.org, person)
            assert client.get(f"/api/invoices/{invoice.id}/").status_code == 200
            assert client.get(f"/api/projects/{project.id}/").status_code == 200
        assert not visible_invoices_qs(outsider).filter(pk=invoice.pk).exists()
        assert not visible_projects_qs(outsider).filter(pk=project.pk).exists()
        client = _make_authenticated_client(outsider.user, outsider.org, outsider)
        assert client.get(f"/api/invoices/{invoice.id}/").status_code == 404
        assert client.get(f"/api/projects/{project.id}/").status_code == 404


class TestRecipients:
    def test_the_creator_and_active_assignees_each_once(
        self, org_a, account, contact, deal, creator, assignee, admin_profile
    ):
        gone = _member(org_a, "gone@test.com", active=False)
        estimate = _proposal(
            org_a, account, contact, deal, creator, [assignee, creator, gone]
        )
        _accept(estimate.public_token)
        notes = _notes()
        assert sorted(n.recipient_id for n in notes) == sorted(
            [creator.id, assignee.id]
        )
        for note in notes:
            assert note.actor is None
            assert note.org_id == org_a.id
            assert note.entity_type == "Estimate" and note.entity_id == estimate.id

    def test_with_no_one_on_the_estimate_its_admins(
        self, org_a, account, contact, deal, admin_profile, creator
    ):
        _member(org_a, "old-admin@test.com", role="ADMIN", active=False)
        second = _member(org_a, "admin2@test.com", role="ADMIN")
        estimate = _proposal(org_a, account, contact, deal, None)
        _accept(estimate.public_token)
        assert {n.recipient for n in _notes()} == {admin_profile, second}

    def test_an_inactive_creator_falls_back_to_admins(
        self, org_a, account, contact, deal, admin_profile, creator
    ):
        estimate = _proposal(org_a, account, contact, deal, creator)
        Profile.objects.filter(pk=creator.pk).update(is_active=False)
        _accept(estimate.public_token)
        assert {n.recipient for n in _notes()} == {admin_profile}

    def test_another_orgs_people_are_never_told(
        self, org_a, org_b, account, contact, deal, creator, profile_b
    ):
        estimate = _proposal(org_a, account, contact, deal, creator)
        _accept(estimate.public_token)
        assert not Notification.objects.filter(org=org_b).exists()
        assert not Notification.objects.filter(recipient=profile_b).exists()


class TestDecline:
    def test_declining_notifies_and_makes_nothing(self, make, creator, assignee):
        estimate = make(start_project=True, deposit_percent=Decimal("50"))
        res = APIClient().post(f"/api/public/estimate/{estimate.public_token}/decline/")
        assert res.status_code == 200
        estimate.refresh_from_db()
        assert estimate.status == "Declined"
        assert not Project.objects.exists() and not Invoice.objects.exists()
        notes = _notes("estimate.declined")
        assert {n.recipient for n in notes} == {creator, assignee}
        assert notes[0].link == "/invoices/estimates"
        assert notes[0].data == {
            "estimate_number": estimate.estimate_number,
            "client_name": "Northwind Ltd",
        }
        assert not _notes()

    def test_a_refused_decline_notifies_no_one(self, make):
        estimate = make()
        Estimate.objects.filter(pk=estimate.pk).update(status="Draft")
        res = APIClient().post(f"/api/public/estimate/{estimate.public_token}/decline/")
        assert res.status_code == 400
        assert not Notification.objects.exists()


def test_an_unknown_token_makes_nothing():
    Org.objects.create(name="Bystander")
    res = _accept("not-a-real-token")
    assert res.status_code == 404
    assert not Project.objects.exists() and not Notification.objects.exists()
