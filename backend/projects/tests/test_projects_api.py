"""The projects API: list, create, detail, edit, delete, comments, files, the
draft from a deal, rates and the burn block, each refusal proven both ways."""

import datetime
from decimal import Decimal

import pytest
from django.core.files.uploadedfile import SimpleUploadedFile
from django.utils import timezone

from accounts.models import Account
from cases.models import TimeEntry
from common.models import Attachments, Comment, CustomFieldDefinition, Profile, Tags
from common.testing import set_modules_off
from conftest import rls_org
from invoices.models import Invoice
from opportunity.models import Opportunity
from projects.models import Project, ProjectRate
from projects.tests.conftest import log_time, make_project
from tasks.models import Task

URL = "/api/projects/"

LIST_KEYS = {
    "id", "name", "account", "deal", "status", "billing_type", "currency",
    "budget_hours", "budget_amount", "hourly_rate", "start_date", "due_date",
    "assigned_to", "tags", "burn", "created_at", "updated_at",
    "retainer_fee", "retainer_hours", "retainer_rollover",
    "retainer_overage_rate", "retainer_carried_hours", "retainer_next_month",
    "retainer_last_month",
}  # fmt: skip
DETAIL_KEYS = LIST_KEYS | {
    "description", "custom_fields", "retainer_usage", "rates", "comments", "attachments",
    "invoices", "estimate", "can_edit", "can_delete", "can_bill",
}  # fmt: skip
BURN_KEYS = {
    "logged_hours", "billable_hours", "billable_value", "unbilled_value",
    "invoiced_amount", "hours_percent", "amount_percent",
}  # fmt: skip


def detail(pk):
    return f"{URL}{pk}/"


@pytest.mark.django_db
class TestCreate:
    def test_an_admin_creates_a_project_with_defaults(
        self, admin_client, org_a, account
    ):
        org_a.default_currency = "EUR"
        org_a.save()

        response = admin_client.post(
            URL, {"name": "Site build", "account": str(account.id)}, format="json"
        )

        assert response.status_code == 201
        body = response.json()
        assert body["error"] is False
        assert set(body["project"]) == DETAIL_KEYS
        project = Project.objects.get(pk=body["id"])
        assert body["project"]["id"] == str(project.id)
        assert (project.status, project.billing_type, project.currency) == (
            "active",
            "time_and_materials",
            "EUR",
        )
        assert body["project"]["account"] == {
            "id": str(account.id),
            "name": "Reyes & Co",
        }
        assert body["project"]["deal"] is None
        assert set(body["project"]["burn"]) == BURN_KEYS
        assert body["project"]["can_bill"] is True

    def test_a_member_creates_one_on_an_account_they_may_open(
        self, user_client, regular_user, member_account
    ):
        response = user_client.post(
            URL,
            {
                "name": "Audit",
                "account": str(member_account.id),
                "start_date": "2026-11-01",
                "due_date": "2026-12-01",
                "description": "Year end",
            },
            format="json",
        )

        assert response.status_code == 201
        project = Project.objects.get(pk=response.json()["id"])
        assert project.created_by_id == regular_user.id
        body = response.json()["project"]
        assert (body["start_date"], body["due_date"]) == ("2026-11-01", "2026-12-01")
        assert body["description"] == "Year end"
        assert body["can_bill"] is False
        assert body["can_delete"] is True

    def test_people_tags_rates_and_custom_fields(
        self, admin_client, org_a, account, admin_profile, user_profile
    ):
        tag = Tags.objects.create(name="Retainer", org=org_a)
        CustomFieldDefinition.objects.create(
            org=org_a, target_model="Project", key="po", label="PO", field_type="text"
        )

        response = admin_client.post(
            URL,
            {
                "name": "Site build",
                "account": str(account.id),
                "assigned_to": [str(user_profile.id)],
                "tags": [str(tag.id)],
                "rates": [{"profile": str(user_profile.id), "hourly_rate": "90"}],
                "custom_fields": {"po": "PO-7"},
            },
            format="json",
        )

        assert response.status_code == 201, response.json()
        body = response.json()["project"]
        assert [p["id"] for p in body["assigned_to"]] == [str(user_profile.id)]
        assert [t["id"] for t in body["tags"]] == [str(tag.id)]
        assert body["rates"] == [
            {
                "profile": body["assigned_to"][0],
                "hourly_rate": "90.00",
            }
        ]
        assert body["custom_fields"] == {"po": "PO-7"}

    @pytest.mark.parametrize(
        "change, field",
        [
            ({"name": ""}, "name"),
            ({"budget_hours": "-1"}, "budget_hours"),
            ({"budget_amount": "-0.01"}, "budget_amount"),
            ({"hourly_rate": "-5"}, "hourly_rate"),
            ({"start_date": "2026-11-02", "due_date": "2026-11-01"}, "due_date"),
            ({"status": "archived"}, "status"),
            ({"billing_type": "subscription"}, "billing_type"),
            ({"currency": "XYZ"}, "currency"),
            ({"account": "not-an-id"}, "account"),
            ({"assigned_to": ["nope"]}, "assigned_to"),
            ({"rates": "nope"}, "rates"),
            ({"rates": [{"hourly_rate": "5"}]}, "rates"),
        ],
    )
    def test_bad_input_is_a_400_and_writes_nothing(
        self, admin_client, account, change, field
    ):
        body = {"name": "Site build", "account": str(account.id), **change}

        response = admin_client.post(URL, body, format="json")

        assert response.status_code == 400
        assert response.json()["error"] is True
        assert field in response.json()["errors"]
        assert not Project.objects.exists()

    def test_another_orgs_account_reads_as_unknown(self, admin_client, org_b):
        with rls_org(org_b):
            theirs = Account.objects.create(name="Theirs", org=org_b)

        response = admin_client.post(
            URL, {"name": "X", "account": str(theirs.id)}, format="json"
        )

        assert response.status_code == 400
        assert response.json()["errors"]["account"] == ["No such account."]

    def test_an_account_the_member_may_not_open_is_refused(
        self, user_client, account, member_account
    ):
        refused = user_client.post(
            URL, {"name": "X", "account": str(account.id)}, format="json"
        )
        allowed = user_client.post(
            URL, {"name": "X", "account": str(member_account.id)}, format="json"
        )

        assert refused.status_code == 400
        assert refused.json()["errors"]["account"] == ["No such account."]
        assert allowed.status_code == 201

    def test_a_deal_the_member_may_not_open_is_refused(
        self, user_client, org_a, admin_user, regular_user, member_account
    ):
        hidden = Opportunity.objects.create(
            name="Hidden", org=org_a, created_by=admin_user
        )
        mine = Opportunity.objects.create(
            name="Mine", org=org_a, created_by=regular_user
        )
        body = {"name": "X", "account": str(member_account.id)}

        refused = user_client.post(URL, {**body, "deal": str(hidden.id)}, format="json")
        allowed = user_client.post(URL, {**body, "deal": str(mine.id)}, format="json")

        assert refused.status_code == 400
        assert refused.json()["errors"]["deal"] == ["No such deal."]
        assert allowed.status_code == 201
        assert allowed.json()["project"]["deal"] == {"id": str(mine.id), "name": "Mine"}

    def test_another_orgs_deal_is_refused(self, admin_client, account, org_b):
        with rls_org(org_b):
            theirs = Opportunity.objects.create(name="Theirs", org=org_b)

        response = admin_client.post(
            URL,
            {"name": "X", "account": str(account.id), "deal": str(theirs.id)},
            format="json",
        )

        assert response.status_code == 400
        assert "deal" in response.json()["errors"]

    def test_an_inactive_assignee_is_refused(
        self, admin_client, account, user_profile, other_member
    ):
        Profile.objects.filter(pk=other_member.pk).update(is_active=False)
        body = {"name": "X", "account": str(account.id)}

        refused = admin_client.post(
            URL, {**body, "assigned_to": [str(other_member.id)]}, format="json"
        )
        allowed = admin_client.post(
            URL, {**body, "assigned_to": [str(user_profile.id)]}, format="json"
        )

        assert refused.status_code == 400
        assert "assigned_to" in refused.json()["errors"]
        assert allowed.status_code == 201

    def test_another_orgs_person_cannot_be_assigned_or_rated(
        self, admin_client, account, profile_b
    ):
        body = {"name": "X", "account": str(account.id)}
        for extra in (
            {"assigned_to": [str(profile_b.id)]},
            {"rates": [{"profile": str(profile_b.id), "hourly_rate": "10"}]},
        ):
            response = admin_client.post(URL, {**body, **extra}, format="json")
            assert response.status_code == 400
            assert set(response.json()["errors"]) == set(extra)
        assert not Project.objects.exists()

    def test_a_rate_for_a_non_member_or_twice_for_one_person_is_refused(
        self, admin_client, account, user_profile, other_member
    ):
        Profile.objects.filter(pk=other_member.pk).update(is_active=False)
        body = {"name": "X", "account": str(account.id)}
        bad = (
            [{"profile": str(other_member.id), "hourly_rate": "10"}],
            [
                {"profile": str(user_profile.id), "hourly_rate": "10"},
                {"profile": str(user_profile.id), "hourly_rate": "20"},
            ],
            [{"profile": str(user_profile.id), "hourly_rate": "-1"}],
            [{"profile": str(user_profile.id), "hourly_rate": None}],
        )
        for rates in bad:
            response = admin_client.post(URL, {**body, "rates": rates}, format="json")
            assert response.status_code == 400, rates
            assert "rates" in response.json()["errors"]
        assert not Project.objects.exists()

    def test_a_custom_field_is_validated(self, admin_client, org_a, account):
        CustomFieldDefinition.objects.create(
            org=org_a,
            target_model="Project",
            key="size",
            label="Size",
            field_type="number",
            is_required=True,
        )

        response = admin_client.post(
            URL, {"name": "X", "account": str(account.id)}, format="json"
        )

        assert response.status_code == 400
        assert "custom_fields" in response.json()["errors"]


@pytest.mark.django_db
class TestList:
    def test_admins_see_every_project_newest_first(self, admin_client, org_a, account):
        old = make_project(org_a, account, name="Old")
        new = make_project(org_a, account, name="New")
        Project.objects.filter(pk=old.pk).update(
            created_at=timezone.now() - datetime.timedelta(days=1)
        )

        body = admin_client.get(URL).json()

        assert body["count"] == 2
        assert [p["id"] for p in body["projects"]] == [str(new.id), str(old.id)]
        assert set(body["projects"][0]) == LIST_KEYS

    def test_a_member_sees_what_they_created_or_are_assigned(
        self, user_client, org_a, account, admin_user, regular_user, user_profile
    ):
        created = make_project(org_a, account, created_by=regular_user, name="Mine")
        assigned = make_project(
            org_a, account, created_by=admin_user, assigned=[user_profile], name="On"
        )
        make_project(org_a, account, created_by=admin_user, name="Hidden")

        body = user_client.get(URL).json()

        assert body["count"] == 2
        assert {p["id"] for p in body["projects"]} == {
            str(created.id),
            str(assigned.id),
        }

    def test_another_orgs_projects_never_list(self, org_b_client, org_a, account):
        make_project(org_a, account)

        assert org_b_client.get(URL).json() == {"projects": [], "count": 0}

    def test_filters(self, admin_client, org_a, account, user_profile, admin_user):
        other = Account.objects.create(name="Other", org=org_a, created_by=admin_user)
        a = make_project(org_a, account, name="Alpha site", assigned=[user_profile])
        make_project(org_a, other, name="Beta", status="on_hold")

        def ids(**params):
            return [p["id"] for p in admin_client.get(URL, params).json()["projects"]]

        assert ids(status="active") == [str(a.id)]
        assert ids(account=str(account.id)) == [str(a.id)]
        assert ids(assigned_to=str(user_profile.id)) == [str(a.id)]
        assert ids(search="ALPHA") == [str(a.id)]
        assert ids(status="nonsense") == []

    def test_limit_and_offset(self, admin_client, org_a, account):
        for i in range(3):
            make_project(org_a, account, name=f"P{i}")

        page = admin_client.get(URL, {"limit": 2, "offset": 2}).json()

        assert page["count"] == 3
        assert len(page["projects"]) == 1
        assert len(admin_client.get(URL, {"limit": 1000}).json()["projects"]) == 3

    @pytest.mark.parametrize(
        "params",
        [{"account": "x"}, {"assigned_to": "x"}, {"limit": "x"}, {"offset": "-1"}],
    )
    def test_malformed_params_are_400s(self, admin_client, params):
        assert admin_client.get(URL, params).status_code == 400


@pytest.mark.django_db
class TestDetailAndEdit:
    def test_who_may_open_a_project(
        self,
        admin_client,
        user_client,
        other_member_client,
        org_b_client,
        org_a,
        account,
        admin_user,
        user_profile,
    ):
        project = make_project(
            org_a, account, created_by=admin_user, assigned=[user_profile]
        )

        assert admin_client.get(detail(project.id)).status_code == 200
        body = user_client.get(detail(project.id)).json()
        assert set(body) == DETAIL_KEYS
        assert (body["can_edit"], body["can_delete"], body["can_bill"]) == (
            True,
            False,
            False,
        )
        for client in (other_member_client, org_b_client):
            response = client.get(detail(project.id))
            assert response.status_code == 404
            assert response.json() == {"error": True, "errors": "Project not found."}

    def test_an_assignee_edits_and_an_outsider_gets_404(
        self, user_client, other_member_client, org_a, account, admin_user, user_profile
    ):
        project = make_project(
            org_a, account, created_by=admin_user, assigned=[user_profile]
        )

        refused = other_member_client.patch(
            detail(project.id), {"name": "Taken"}, format="json"
        )
        allowed = user_client.patch(
            detail(project.id), {"name": "Renamed", "status": "on_hold"}, format="json"
        )

        assert refused.status_code == 404
        assert allowed.status_code == 200
        assert allowed.json()["project"]["name"] == "Renamed"
        project.refresh_from_db()
        assert (project.name, project.status) == ("Renamed", "on_hold")
        # A member keeps an account they cannot open themselves.
        assert project.account_id == account.id

    def test_patch_judges_dates_against_what_is_stored(
        self, admin_client, org_a, account
    ):
        project = make_project(org_a, account, start_date=datetime.date(2026, 11, 10))

        response = admin_client.patch(
            detail(project.id), {"due_date": "2026-11-01"}, format="json"
        )

        assert response.status_code == 400
        assert "due_date" in response.json()["errors"]

    def test_rates_replace_the_whole_list(
        self, admin_client, org_a, account, user_profile, admin_profile
    ):
        project = make_project(org_a, account)
        ProjectRate.objects.create(
            org=org_a, project=project, profile=user_profile, hourly_rate=50
        )

        response = admin_client.patch(
            detail(project.id),
            {"rates": [{"profile": str(admin_profile.id), "hourly_rate": "200"}]},
            format="json",
        )

        assert response.status_code == 200
        assert list(project.rates.values_list("profile_id", "hourly_rate")) == [
            (admin_profile.id, Decimal("200.00"))
        ]
        assert (
            admin_client.patch(
                detail(project.id), {"rates": []}, format="json"
            ).status_code
            == 200
        )
        assert not project.rates.exists()

    def test_a_patch_that_omits_rates_keeps_them(
        self, admin_client, org_a, account, user_profile
    ):
        project = make_project(org_a, account)
        ProjectRate.objects.create(
            org=org_a, project=project, profile=user_profile, hourly_rate=50
        )

        admin_client.patch(detail(project.id), {"name": "Again"}, format="json")

        assert project.rates.count() == 1

    def test_comments_and_files_post_like_a_deal(
        self, user_client, other_member_client, org_a, account, regular_user
    ):
        project = make_project(org_a, account, created_by=regular_user)
        upload = SimpleUploadedFile("brief.txt", b"scope", content_type="text/plain")

        response = user_client.post(
            detail(project.id),
            {"comment": "Kick-off done", "project_attachment": upload},
            format="multipart",
        )

        assert response.status_code == 200
        body = response.json()
        assert [c["comment"] for c in body["comments"]] == ["Kick-off done"]
        assert [a["file_name"] for a in body["attachments"]] == ["brief.txt"]
        hidden = other_member_client.post(
            detail(project.id), {"comment": "Sneaky"}, format="json"
        )
        assert hidden.status_code == 404
        assert Comment.objects.count() == 1
        assert Attachments.objects.count() == 1


@pytest.mark.django_db
class TestDelete:
    def test_an_assignee_may_not_delete_but_the_creator_may(
        self,
        user_client,
        other_member_client,
        org_a,
        account,
        regular_user,
        other_member,
    ):
        project = make_project(
            org_a, account, created_by=regular_user, assigned=[other_member]
        )

        assert other_member_client.delete(detail(project.id)).status_code == 403
        assert Project.objects.filter(pk=project.pk).exists()
        assert user_client.delete(detail(project.id)).status_code == 204
        assert not Project.objects.filter(pk=project.pk).exists()

    def test_hidden_and_foreign_projects_answer_404(
        self, other_member_client, org_b_client, org_a, account, admin_user
    ):
        project = make_project(org_a, account, created_by=admin_user)

        assert other_member_client.delete(detail(project.id)).status_code == 404
        assert org_b_client.delete(detail(project.id)).status_code == 404
        assert Project.objects.filter(pk=project.pk).exists()

    def test_an_account_with_a_project_is_not_deleted(
        self, admin_client, org_a, account
    ):
        project = make_project(org_a, account)
        url = f"/api/accounts/{account.id}/"

        refused = admin_client.delete(url)

        assert refused.status_code == 409
        assert refused.json()["errors"] == (
            "This account can't be deleted while it still has projects, invoices, "
            "estimates or recurring invoices linked to it."
        )
        assert Account.objects.filter(pk=account.pk).exists()
        project.delete()
        assert admin_client.delete(url).status_code == 200

    def test_an_account_with_a_project_while_projects_is_off(
        self, admin_client, org_a, account
    ):
        make_project(org_a, account)
        set_modules_off(org_a, "projects")

        response = admin_client.delete(f"/api/accounts/{account.id}/")

        assert response.status_code == 409
        assert response.json()["module"] == "projects"
        assert response.json()["errors"].startswith("This account has 1 project.")

    def test_time_invoices_and_tasks_are_kept_unlinked(
        self, admin_client, org_a, account, admin_profile
    ):
        project = make_project(org_a, account)
        entry = log_time(project, admin_profile, 60)
        invoice = Invoice.objects.create(
            invoice_title="Fee", account=account, org=org_a, project=project
        )
        task = Task.objects.create(
            title="Design", status="New", priority="Low", org=org_a, project=project
        )

        assert admin_client.delete(detail(project.id)).status_code == 204

        for record in (entry, invoice, task):
            record.refresh_from_db()
            assert record.project_id is None
        assert (entry.case_id, entry.duration_minutes) == (None, 60)


@pytest.mark.django_db
class TestFromDeal:
    def test_a_deal_with_an_amount_drafts_a_fixed_fee(
        self, admin_client, org_a, account, user_profile, other_member
    ):
        deal = Opportunity.objects.create(
            name="Rebrand",
            org=org_a,
            account=account,
            amount=Decimal("8000"),
            currency="GBP",
        )
        deal.assigned_to.set([user_profile, other_member])
        Profile.objects.filter(pk=other_member.pk).update(is_active=False)

        response = admin_client.get(f"{URL}from-deal/{deal.id}/")

        assert response.status_code == 200
        assert response.json() == {
            "name": "Rebrand",
            "account": {"id": str(account.id), "name": "Reyes & Co"},
            "deal": {"id": str(deal.id), "name": "Rebrand"},
            "currency": "GBP",
            "assigned_to": [str(user_profile.id)],
            "billing_type": "fixed_fee",
            "budget_amount": "8000.00",
        }
        assert not Project.objects.exists()

    def test_a_deal_without_an_amount_drafts_time_and_materials(
        self, admin_client, org_a
    ):
        org_a.default_currency = "INR"
        org_a.save()
        deal = Opportunity.objects.create(name="Retainer", org=org_a)

        body = admin_client.get(f"{URL}from-deal/{deal.id}/").json()

        assert (body["billing_type"], body["budget_amount"], body["account"]) == (
            "time_and_materials",
            None,
            None,
        )
        assert body["currency"] == "INR"

    def test_a_deal_the_caller_cannot_see_is_404(
        self, user_client, org_b_client, org_a, admin_user, regular_user
    ):
        hidden = Opportunity.objects.create(name="H", org=org_a, created_by=admin_user)
        mine = Opportunity.objects.create(name="M", org=org_a, created_by=regular_user)

        assert user_client.get(f"{URL}from-deal/{hidden.id}/").status_code == 404
        assert user_client.get(f"{URL}from-deal/{mine.id}/").status_code == 200
        assert org_b_client.get(f"{URL}from-deal/{mine.id}/").status_code == 404


@pytest.mark.django_db
class TestBurn:
    def test_burn_counts_everyone_stopped_and_in_the_projects_currency(
        self, admin_client, org_a, account, admin_profile, user_profile, regular_user
    ):
        project = make_project(
            org_a,
            account,
            created_by=regular_user,
            budget_hours=Decimal("10"),
            budget_amount=Decimal("1000"),
            currency="USD",
        )
        log_time(project, admin_profile, 240, rate="100")  # 400 billable
        billed = log_time(project, user_profile, 60, rate="100")  # 100, billed
        log_time(project, user_profile, 120, billable=False)
        log_time(project, user_profile, 30, rate=None)  # billable, no rate
        TimeEntry.objects.create(
            org=org_a,
            project=project,
            profile=admin_profile,
            started_at=timezone.now(),
            billable=True,
            hourly_rate=Decimal("100"),
            currency="USD",
        )  # running: never counted
        invoice = Invoice.objects.create(
            invoice_title="T", account=account, org=org_a, project=project
        )
        Invoice.objects.filter(pk=invoice.pk).update(
            subtotal=Decimal("100"), total_amount=Decimal("100")
        )
        TimeEntry.objects.filter(pk=billed.pk).update(invoice=invoice)
        cancelled = Invoice.objects.create(
            invoice_title="C", account=account, org=org_a, project=project
        )
        Invoice.objects.filter(pk=cancelled.pk).update(
            subtotal=Decimal("999"), total_amount=Decimal("999"), status="Cancelled"
        )

        burn = admin_client.get(detail(project.id)).json()["burn"]

        assert burn == {
            "logged_hours": "7.50",
            "billable_hours": "5.50",
            "billable_value": "500.00",
            "unbilled_value": "400.00",
            "invoiced_amount": "100.00",
            "hours_percent": 75,
            "amount_percent": 50,
        }

    def test_percents_are_null_without_a_budget(self, admin_client, org_a, account):
        project = make_project(org_a, account)

        burn = admin_client.get(detail(project.id)).json()["burn"]

        assert (burn["hours_percent"], burn["amount_percent"]) == (None, None)
        assert burn["logged_hours"] == "0.00"

    def test_the_list_carries_each_rows_burn(
        self, admin_client, org_a, account, admin_profile
    ):
        one = make_project(org_a, account, name="One")
        make_project(org_a, account, name="Two")
        log_time(one, admin_profile, 90)

        rows = {p["name"]: p["burn"] for p in admin_client.get(URL).json()["projects"]}

        assert rows["One"]["logged_hours"] == "1.50"
        assert rows["Two"]["logged_hours"] == "0.00"


@pytest.mark.django_db
class TestInactivePeople:
    @pytest.fixture
    def project(self, org_a, account, other_member, user_profile):
        project = make_project(org_a, account, assigned=[other_member, user_profile])
        ProjectRate.objects.create(
            org=org_a, project=project, profile=other_member, hourly_rate=40
        )
        Profile.objects.filter(pk=other_member.pk).update(is_active=False)
        return project

    def test_stored_inactive_people_may_be_sent_back(
        self, admin_client, project, other_member, user_profile
    ):
        response = admin_client.patch(
            detail(project.id),
            {
                "name": "Renamed",
                "assigned_to": [str(other_member.id), str(user_profile.id)],
                "rates": [{"profile": str(other_member.id), "hourly_rate": "40"}],
            },
            format="json",
        )

        assert response.status_code == 200, response.json()
        project.refresh_from_db()
        assert project.name == "Renamed"
        assert set(project.assigned_to.values_list("id", flat=True)) == {
            other_member.id,
            user_profile.id,
        }
        assert project.rates.get().profile_id == other_member.id

    def test_a_newly_added_inactive_person_is_refused_by_name(
        self, admin_client, org_a, account, other_member
    ):
        Profile.objects.filter(pk=other_member.pk).update(is_active=False)
        fresh = make_project(org_a, account, name="Fresh")

        for body in (
            {"assigned_to": [str(other_member.id)]},
            {"rates": [{"profile": str(other_member.id), "hourly_rate": "10"}]},
        ):
            response = admin_client.patch(detail(fresh.id), body, format="json")
            assert response.status_code == 400
            (field,) = body
            message = response.json()["errors"][field][0]
            assert message == "other is not an active member of this organization."
            assert str(other_member.id) not in str(response.json())

    def test_an_unknown_person_is_refused_without_their_id(
        self, admin_client, project, profile_b
    ):
        response = admin_client.patch(
            detail(project.id), {"assigned_to": [str(profile_b.id)]}, format="json"
        )

        assert response.status_code == 400
        assert str(profile_b.id) not in str(response.json())
