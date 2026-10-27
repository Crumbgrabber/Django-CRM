"""An estimate's proposal fields: the introduction, the deposit and the project
to start on acceptance (release 2). Writing them, refusing bad values, the
issued lock, the list row and the deposit helper's rounding."""

from decimal import Decimal

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext

from accounts.models import Account
from common.models import Profile, User
from common.testing import _make_authenticated_client, set_modules_off
from contacts.models import Contact
from invoices.models import Estimate, EstimateLineItem, Invoice, InvoiceLineItem
from invoices.proposals import deposit_part, estimate_deposit
from projects.models import Project

URL = "/api/invoices/estimates/"


@pytest.fixture
def account(org_a, admin_user):
    return Account.objects.create(name="Northwind", org=org_a, created_by=admin_user)


@pytest.fixture
def contact(org_a, account, admin_user):
    contact = Contact.objects.create(
        first_name="Nora",
        last_name="Fitz",
        email="nora@example.com",
        org=org_a,
        account=account,
        created_by=admin_user,
    )
    account.contacts.add(contact)
    return contact


def _body(account, contact, **extra):
    return {
        "title": "Brand sprint",
        "account_id": str(account.id),
        "contact_id": str(contact.id),
        "currency": "USD",
        "line_items": [{"description": "Strategy", "quantity": 1, "unit_price": 1000}],
        **extra,
    }


def _estimate(org, account, *, lines=(("1000.00", 1),), status="Draft", **fields):
    estimate = Estimate.objects.create(
        org=org, account=account, title="Brand sprint", currency="USD", **fields
    )
    for price, quantity in lines:
        EstimateLineItem.objects.create(
            estimate=estimate,
            org=org,
            description="Work",
            quantity=Decimal(quantity),
            unit_price=Decimal(price),
        )
    estimate.save()
    if status != "Draft":
        Estimate.objects.filter(pk=estimate.pk).update(status=status)
    estimate.refresh_from_db()
    return estimate


class TestWrite:
    def test_new_fields_are_written_and_read_back(self, admin_client, account, contact):
        intro = "Dear Nora,\n\nHere is our proposal.\n<b>Not HTML</b>"
        res = admin_client.post(
            URL,
            _body(
                account,
                contact,
                introduction=intro,
                deposit_percent="25.5",
                start_project=True,
                project_billing_type="time_and_materials",
            ),
            format="json",
        )
        assert res.status_code == 201, res.json()
        body = res.json()["estimate"]
        assert body["introduction"] == intro
        assert body["deposit_percent"] == "25.50"
        assert body["start_project"] is True
        assert body["project_billing_type"] == "time_and_materials"
        assert body["project"] is None and body["deposit_invoice"] is None
        stored = Estimate.objects.get(pk=body["id"])
        assert stored.deposit_percent == Decimal("25.50")

    def test_defaults(self, admin_client, account, contact):
        res = admin_client.post(URL, _body(account, contact), format="json")
        body = res.json()["estimate"]
        assert (
            body["introduction"],
            body["deposit_percent"],
            body["start_project"],
            body["project_billing_type"],
        ) == ("", None, False, "fixed_fee")

    def test_a_put_edits_them_on_a_draft(self, admin_client, account, org_a):
        estimate = _estimate(org_a, account)
        res = admin_client.put(
            f"{URL}{estimate.pk}/",
            {"deposit_percent": "100", "introduction": "Hello"},
            format="json",
        )
        assert res.status_code == 200, res.json()
        estimate.refresh_from_db()
        assert (estimate.deposit_percent, estimate.introduction) == (
            Decimal("100"),
            "Hello",
        )
        res = admin_client.put(
            f"{URL}{estimate.pk}/", {"deposit_percent": None}, format="json"
        )
        assert res.status_code == 200
        estimate.refresh_from_db()
        assert estimate.deposit_percent is None

    def test_project_and_deposit_invoice_cannot_be_written(
        self, admin_client, account, contact, org_a
    ):
        project = Project.objects.create(org=org_a, name="Other", account=account)
        invoice = Invoice.objects.create(org=org_a, account=account, invoice_title="X")
        res = admin_client.post(
            URL,
            _body(
                account,
                contact,
                project=str(project.id),
                deposit_invoice=str(invoice.id),
                project_id=str(project.id),
            ),
            format="json",
        )
        assert res.status_code == 201
        stored = Estimate.objects.get(pk=res.json()["estimate"]["id"])
        assert (stored.project_id, stored.deposit_invoice_id) == (None, None)


class TestRefusals:
    @pytest.mark.parametrize("value", ["0", "-5", "100.01", "250", "abc"])
    def test_deposit_percent_out_of_range(self, admin_client, account, contact, value):
        res = admin_client.post(
            URL, _body(account, contact, deposit_percent=value), format="json"
        )
        assert res.status_code == 400
        assert "deposit_percent" in res.json()["errors"]
        assert not Estimate.objects.exists()

    def test_deposit_percent_message(self, admin_client, account, contact):
        res = admin_client.post(
            URL, _body(account, contact, deposit_percent="0"), format="json"
        )
        assert res.json()["errors"]["deposit_percent"] == [
            "A deposit must be more than 0% and at most 100%."
        ]

    def test_introduction_over_5000_characters(self, admin_client, account, contact):
        res = admin_client.post(
            URL, _body(account, contact, introduction="x" * 5001), format="json"
        )
        assert res.status_code == 400
        assert "introduction" in res.json()["errors"]
        ok = admin_client.post(
            URL, _body(account, contact, introduction="x" * 5000), format="json"
        )
        assert ok.status_code == 201

    def test_unknown_billing_type(self, admin_client, account, contact):
        res = admin_client.post(
            URL,
            _body(account, contact, project_billing_type="retainer"),
            format="json",
        )
        assert res.status_code == 400
        assert "project_billing_type" in res.json()["errors"]

    def test_start_project_needs_the_projects_module(
        self, admin_client, account, contact, org_a
    ):
        set_modules_off(org_a, "projects")
        res = admin_client.post(
            URL, _body(account, contact, start_project=True), format="json"
        )
        assert res.status_code == 400
        assert res.json()["errors"]["start_project"] == [
            "Projects is switched off for this organization."
        ]
        assert not Estimate.objects.exists()
        # Leaving it off is fine while the module is off.
        res = admin_client.post(
            URL, _body(account, contact, start_project=False), format="json"
        )
        assert res.status_code == 201

    def test_start_project_needs_an_account(self, admin_client, org_a):
        estimate = Estimate.objects.create(org=org_a, title="No account")
        res = admin_client.put(
            f"{URL}{estimate.pk}/", {"start_project": True}, format="json"
        )
        assert res.status_code == 400
        assert res.json()["errors"]["start_project"] == [
            "Choose an account to start a project for."
        ]
        estimate.refresh_from_db()
        assert estimate.start_project is False


ADMIN_ONLY = ["Only an admin can start a project from an estimate."]


class TestOnlyAdminsStartProjects:
    """Release 1 made a project's billing type and budget admin-only; the
    estimate must not be a way round it."""

    @pytest.fixture
    def member_account(self, account, user_profile):
        account.assigned_to.add(user_profile)
        return account

    @pytest.fixture
    def set_up(self, org_a, member_account, user_profile):
        estimate = _estimate(
            org_a,
            member_account,
            start_project=True,
            project_billing_type="time_and_materials",
        )
        estimate.assigned_to.add(user_profile)
        return estimate

    def test_a_member_cannot_create_one_that_starts_a_project(
        self, user_client, member_account, contact
    ):
        res = user_client.post(
            URL, _body(member_account, contact, start_project=True), format="json"
        )
        assert res.status_code == 400
        assert res.json()["errors"]["start_project"] == ADMIN_ONLY
        assert not Estimate.objects.exists()

    def test_nor_choose_the_billing_type(self, user_client, member_account, contact):
        res = user_client.post(
            URL,
            _body(member_account, contact, project_billing_type="non_billable"),
            format="json",
        )
        assert res.status_code == 400
        assert res.json()["errors"]["project_billing_type"] == ADMIN_ONLY
        assert not Estimate.objects.exists()

    def test_a_member_sending_the_defaults_is_fine(
        self, user_client, member_account, contact
    ):
        res = user_client.post(
            URL,
            _body(
                member_account,
                contact,
                start_project=False,
                project_billing_type="fixed_fee",
            ),
            format="json",
        )
        assert res.status_code == 201, res.json()

    @pytest.mark.parametrize(
        "change, refused",
        [
            ({"start_project": False}, "start_project"),
            ({"project_billing_type": "non_billable"}, "project_billing_type"),
            (
                {"start_project": True, "project_billing_type": "fixed_fee"},
                "project_billing_type",
            ),
        ],
    )
    def test_a_member_cannot_change_them(self, user_client, set_up, change, refused):
        res = user_client.put(f"{URL}{set_up.pk}/", change, format="json")
        assert res.status_code == 400
        assert res.json()["errors"] == {refused: ADMIN_ONLY}
        set_up.refresh_from_db()
        assert (set_up.start_project, set_up.project_billing_type) == (
            True,
            "time_and_materials",
        )

    def test_a_member_echoing_them_edits_the_rest(self, user_client, set_up):
        res = user_client.put(
            f"{URL}{set_up.pk}/",
            {
                "start_project": True,
                "project_billing_type": "time_and_materials",
                "introduction": "Updated by the member",
            },
            format="json",
        )
        assert res.status_code == 200, res.json()
        set_up.refresh_from_db()
        assert set_up.introduction == "Updated by the member"
        assert set_up.start_project is True

    def test_an_admin_may_change_them(self, admin_client, set_up):
        res = admin_client.put(
            f"{URL}{set_up.pk}/",
            {"start_project": False, "project_billing_type": "non_billable"},
            format="json",
        )
        assert res.status_code == 200, res.json()
        set_up.refresh_from_db()
        assert (set_up.start_project, set_up.project_billing_type) == (
            False,
            "non_billable",
        )


class TestIssuedLock:
    def test_the_deposit_is_frozen_once_sent(self, admin_client, account, org_a):
        estimate = _estimate(org_a, account, status="Sent", deposit_percent=50)
        res = admin_client.put(
            f"{URL}{estimate.pk}/", {"deposit_percent": "40"}, format="json"
        )
        assert res.status_code == 400
        assert "deposit_percent" in res.json()["errors"]
        res = admin_client.put(
            f"{URL}{estimate.pk}/", {"deposit_percent": None}, format="json"
        )
        assert res.status_code == 400
        estimate.refresh_from_db()
        assert estimate.deposit_percent == Decimal("50")

    def test_resending_the_stored_deposit_is_not_a_change(
        self, admin_client, account, org_a
    ):
        estimate = _estimate(org_a, account, status="Sent", deposit_percent=50)
        res = admin_client.put(
            f"{URL}{estimate.pk}/",
            {"deposit_percent": "50.00", "introduction": "Updated cover"},
            format="json",
        )
        assert res.status_code == 200, res.json()
        estimate.refresh_from_db()
        assert estimate.introduction == "Updated cover"

    def test_a_deposit_cannot_be_added_once_sent(self, admin_client, account, org_a):
        estimate = _estimate(org_a, account, status="Viewed")
        res = admin_client.put(
            f"{URL}{estimate.pk}/", {"deposit_percent": "10"}, format="json"
        )
        assert res.status_code == 400
        estimate.refresh_from_db()
        assert estimate.deposit_percent is None


class TestListRow:
    def test_the_row_carries_the_proposal(self, admin_client, account, org_a):
        estimate = _estimate(
            org_a,
            account,
            tax_rate=Decimal("10"),
            deposit_percent=Decimal("50"),
            introduction="Hi",
            start_project=True,
        )
        project = Project.objects.create(org=org_a, name="Sprint", account=account)
        deposit = Invoice.objects.create(
            org=org_a, account=account, invoice_title="Deposit", currency="USD"
        )
        Estimate.objects.filter(pk=estimate.pk).update(
            project=project, deposit_invoice=deposit
        )
        row = admin_client.get(URL).json()["results"][0]
        assert row["introduction"] == "Hi"
        assert row["deposit_percent"] == "50.00"
        assert row["start_project"] is True
        assert row["project_billing_type"] == "fixed_fee"
        assert row["project"] == {"id": str(project.id), "name": "Sprint"}
        assert row["deposit_invoice"] == {
            "id": str(deposit.id),
            "invoice_number": deposit.invoice_number,
            "status": "Draft",
            "total_amount": "0.00",
        }
        # 1000 pre-tax, half of it, plus 10% tax.
        assert row["deposit"] == {
            "percent": "50.00",
            "amount": "550.00",
            "currency": "USD",
        }

    def test_without_a_proposal(self, admin_client, account, org_a):
        _estimate(org_a, account)
        row = admin_client.get(URL).json()["results"][0]
        assert (row["project"], row["deposit_invoice"], row["deposit"]) == (
            None,
            None,
            None,
        )

    def test_the_project_is_hidden_while_projects_is_off(
        self, admin_client, account, org_a
    ):
        estimate = _estimate(org_a, account)
        project = Project.objects.create(org=org_a, name="Sprint", account=account)
        Estimate.objects.filter(pk=estimate.pk).update(project=project)
        set_modules_off(org_a, "projects")
        row = admin_client.get(URL).json()["results"][0]
        assert row["project"] is None


class TestListRowFollowsAccess:
    """Seeing an estimate is not access to the project or deposit invoice its
    acceptance made."""

    @pytest.fixture
    def made(self, org_a, account, admin_user, user_profile):
        estimate = _estimate(org_a, account, deposit_percent=Decimal("50"))
        estimate.assigned_to.add(user_profile)
        project = Project.objects.create(
            org=org_a, name="Sprint", account=account, created_by=admin_user
        )
        deposit = Invoice.objects.create(
            org=org_a, account=account, invoice_title="Deposit", created_by=admin_user
        )
        Estimate.objects.filter(pk=estimate.pk).update(
            project=project, deposit_invoice=deposit
        )
        return project, deposit

    def test_a_member_on_the_estimate_only_sees_neither(self, user_client, made):
        row = user_client.get(URL).json()["results"][0]
        assert (row["project"], row["deposit_invoice"]) == (None, None)
        # The estimate's own figures stay.
        assert row["deposit"]["amount"] == "500.00"

    def test_each_shows_once_the_member_may_open_it(
        self, user_client, made, user_profile
    ):
        project, deposit = made
        project.assigned_to.add(user_profile)
        row = user_client.get(URL).json()["results"][0]
        assert row["project"] == {"id": str(project.id), "name": "Sprint"}
        assert row["deposit_invoice"] is None

        deposit.assigned_to.add(user_profile)
        row = user_client.get(URL).json()["results"][0]
        assert row["deposit_invoice"]["id"] == str(deposit.id)

    def test_a_project_the_member_created_shows(self, user_client, made, regular_user):
        project, _deposit = made
        Project.objects.filter(pk=project.pk).update(created_by=regular_user)
        row = user_client.get(URL).json()["results"][0]
        assert row["project"]["id"] == str(project.id)

    def test_another_member_sees_no_estimate_at_all(self, org_a, made):
        user = User.objects.create_user(email="other@test.com", password="pw")
        other = Profile.objects.create(user=user, org=org_a, role="USER")
        client = _make_authenticated_client(user, org_a, other)
        assert client.get(URL).json()["results"] == []

    def test_no_query_per_row(self, org_a, account, admin_user, user_profile):
        client = _make_authenticated_client(user_profile.user, org_a, user_profile)

        def add_one(n):
            estimate = _estimate(org_a, account, deposit_percent=Decimal("10"))
            estimate.assigned_to.add(user_profile)
            project = Project.objects.create(org=org_a, name=f"P{n}", account=account)
            project.assigned_to.add(user_profile)
            deposit = Invoice.objects.create(
                org=org_a, account=account, invoice_title=f"D{n}"
            )
            deposit.assigned_to.add(user_profile)
            Estimate.objects.filter(pk=estimate.pk).update(
                project=project, deposit_invoice=deposit
            )

        def queries():
            with CaptureQueriesContext(connection) as ctx:
                rows = client.get(URL).json()["results"]
            assert all(r["project"] and r["deposit_invoice"] for r in rows)
            return len(ctx.captured_queries)

        add_one(1)
        one = queries()
        add_one(2)
        add_one(3)
        assert queries() == one


def _invoice_total(org, account, unit_price, tax_rate):
    """What an invoice with one line of ``unit_price`` totals, stored."""
    invoice = Invoice.objects.create(
        org=org, account=account, invoice_title="Check", tax_rate=tax_rate
    )
    InvoiceLineItem.objects.create(
        invoice=invoice, org=org, quantity=1, unit_price=unit_price
    )
    invoice.recalculate_totals()
    invoice.save()
    invoice.refresh_from_db()
    return invoice.total_amount


class TestDepositHelper:
    @pytest.mark.parametrize(
        "lines, discount, tax, percent, part, amount",
        [
            # 1000 less 10% is 900; a third of it; 8.25% tax on 299.97.
            (
                (("1000.00", 1),),
                ("PERCENTAGE", "10"),
                "8.25",
                "33.33",
                "299.97",
                "324.72",
            ),
            # 250 less a flat 20 is 230; 15% is 34.50; 20% tax.
            ((("125.00", 2),), ("FIXED", "20"), "20", "15", "34.50", "41.40"),
            # Half of 10.05 is 5.025, which rounds half up to 5.03.
            ((("10.05", 1),), ("", "0"), "0", "50", "5.03", "5.03"),
            # Two lines, no discount, the whole amount.
            ((("99.99", 3), ("0.01", 1)), ("", "0"), "5", "100", "299.98", "314.98"),
        ],
    )
    def test_the_amount_is_what_an_invoice_totals(
        self, org_a, account, lines, discount, tax, percent, part, amount
    ):
        estimate = _estimate(
            org_a,
            account,
            lines=lines,
            discount_type=discount[0],
            discount_value=Decimal(discount[1]),
            tax_rate=Decimal(tax),
            deposit_percent=Decimal(percent),
        )
        assert deposit_part(estimate) == Decimal(part)
        deposit = estimate_deposit(estimate)
        assert deposit["amount"] == amount
        assert deposit["amount"] == str(
            _invoice_total(org_a, account, Decimal(part), Decimal(tax))
        )
        assert deposit["currency"] == "USD"
        assert deposit["percent"] == str(Decimal(percent).quantize(Decimal("0.01")))

    def test_no_deposit_is_none(self, org_a, account):
        assert estimate_deposit(_estimate(org_a, account)) is None

    @pytest.mark.parametrize(
        "lines, discount, percent",
        [
            # 0.01% of 10.00 is 0.001, which rounds to 0.00.
            ((("10.00", 1),), ("", "0"), "0.01"),
            # A flat discount equal to the subtotal leaves nothing to share.
            ((("100.00", 1),), ("FIXED", "100"), "50"),
        ],
    )
    def test_a_deposit_totalling_nothing_is_none(
        self, org_a, account, lines, discount, percent
    ):
        estimate = _estimate(
            org_a,
            account,
            lines=lines,
            discount_type=discount[0],
            discount_value=Decimal(discount[1]),
            tax_rate=Decimal("20"),
            deposit_percent=Decimal(percent),
        )
        assert estimate_deposit(estimate) is None

    @pytest.mark.parametrize(
        "price, quantity, discount, percent, amount",
        [
            # 10.01 less 15% (1.5015 in memory, 1.50 stored) is 8.51; half is
            # 4.255, so 4.26 either way rather than 4.25 from 8.5085.
            ("10.01", "1", ("PERCENTAGE", "15"), "50", "4.26"),
            # 1.5 x 1.03 is 1.545, 1.55 to the cent; 30% of it is 0.465.
            ("1.03", "1.5", ("", "0"), "30", "0.47"),
        ],
    )
    def test_the_same_before_and_after_a_reload(
        self, org_a, account, price, quantity, discount, percent, amount
    ):
        estimate = Estimate.objects.create(
            org=org_a,
            account=account,
            currency="USD",
            discount_type=discount[0],
            discount_value=Decimal(discount[1]),
            deposit_percent=Decimal(percent),
        )
        EstimateLineItem.objects.create(
            estimate=estimate,
            org=org_a,
            description="Work",
            quantity=Decimal(quantity),
            unit_price=Decimal(price),
        )
        estimate.recalculate_totals()
        assert deposit_part(estimate) == Decimal(amount)
        assert estimate_deposit(estimate)["amount"] == amount
        estimate.save()
        estimate.refresh_from_db()
        assert deposit_part(estimate) == Decimal(amount)
        assert estimate_deposit(estimate)["amount"] == amount

    def test_a_cent_is_a_deposit(self, org_a, account):
        # 0.01% of 50.00 is 0.005, which rounds half up to 0.01.
        estimate = _estimate(
            org_a, account, lines=(("50.00", 1),), deposit_percent=Decimal("0.01")
        )
        assert estimate_deposit(estimate)["amount"] == "0.01"

    def test_the_helper_reads_no_rows(self, org_a, account, django_assert_num_queries):
        estimate = _estimate(org_a, account, deposit_percent=Decimal("20"))
        estimate = Estimate.objects.get(pk=estimate.pk)
        with django_assert_num_queries(0):
            estimate_deposit(estimate)
