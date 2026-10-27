"""
Tests for tag management views: list, create, detail, update, soft-delete, restore.

Run with: pytest common/tests/test_tags.py -v
"""

from dataclasses import dataclass

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext
from rest_framework import status

from accounts.models import Account
from cases.models import Case, Solution
from common import object_registry
from common.models import APISettings, Tags
from common.testing import set_modules_off
from common.views import tags_views
from contacts.models import Contact
from leads.models import Lead
from opportunity.models import Opportunity
from tasks.models import Task


def _tag_row(response, tag_id):
    return next(r for r in response.data["tags"] if r["id"] == str(tag_id))


def _tag_row_by_id(body, tag_id):
    """Same lookup against an already-unwrapped response body."""
    return next(r for r in body["tags"] if r["id"] == str(tag_id))


@dataclass(frozen=True)
class SliceEntry:
    """A hook entry over some rows of one model, as each custom object is over
    some rows of the table they all share."""

    key: str
    label_plural: str
    model: type
    field: str
    prefix: str

    @property
    def custom_field_target(self):
        return self.key

    @property
    def tags_key(self):
        return self.key

    def records(self, org):
        lookup = {f"{self.field}__startswith": self.prefix}
        return self.model.objects.filter(org=org, **lookup)


def _hook(monkeypatch, *entries):
    monkeypatch.setattr(
        object_registry, "_HOOKS", [lambda org: entries if org is not None else ()]
    )


@pytest.mark.django_db
class TestTagsListView:
    """Tests for GET/POST /api/tags/"""

    url = "/api/tags/"

    def test_create_tag(self, admin_client, org_a):
        response = admin_client.post(
            self.url,
            {"name": "Important"},
            format="json",
        )
        assert response.status_code == status.HTTP_201_CREATED
        assert response.data["error"] is False
        assert response.data["tag"]["name"] == "Important"

    def test_list_tags(self, admin_client, org_a):
        Tags.objects.create(name="Urgent", slug="urgent", org=org_a)
        response = admin_client.get(self.url)
        assert response.status_code == status.HTTP_200_OK
        assert "tags" in response.data
        assert response.data["tags_count"] >= 1

    def test_unauthenticated(self, unauthenticated_client):
        # DRF converts the auth failure into a 401/403 Response (it does not
        # propagate the exception through the test client), so assert on the
        # status. The endpoint still rejects an anonymous caller.
        resp = unauthenticated_client.get(self.url)
        assert resp.status_code in (
            status.HTTP_401_UNAUTHORIZED,
            status.HTTP_403_FORBIDDEN,
        )

    def test_create_tag_non_admin_forbidden(self, user_client, org_a):
        """Non-admin user cannot create tags."""
        response = user_client.post(
            self.url,
            {"name": "No Permission"},
            format="json",
        )
        assert response.status_code == status.HTTP_403_FORBIDDEN

    def test_create_tag_empty_name(self, admin_client, org_a):
        """Creating a tag with empty name should fail."""
        response = admin_client.post(
            self.url,
            {"name": ""},
            format="json",
        )
        assert response.status_code == status.HTTP_400_BAD_REQUEST

    def test_create_tag_duplicate_name(self, admin_client, org_a):
        """Creating a tag with duplicate name in same org should fail."""
        Tags.objects.create(name="Duplicate", slug="duplicate", org=org_a)
        response = admin_client.post(
            self.url,
            {"name": "Duplicate"},
            format="json",
        )
        assert response.status_code == status.HTTP_400_BAD_REQUEST

    def test_create_tag_reactivate_archived(self, admin_client, org_a):
        """Creating tag with same name as archived tag reactivates it."""
        Tags.objects.create(
            name="Archived Tag", slug="archived-tag", org=org_a, is_active=False
        )
        response = admin_client.post(
            self.url,
            {"name": "Archived Tag"},
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False
        assert "reactivated" in response.data["message"].lower()

    def test_create_tag_with_color(self, admin_client, org_a):
        """Create a tag with a specific color."""
        response = admin_client.post(
            self.url,
            {"name": "Red Tag", "color": "red"},
            format="json",
        )
        assert response.status_code == status.HTTP_201_CREATED
        assert response.data["tag"]["color"] == "red"

    def test_create_tag_invalid_color_defaults_to_blue(self, admin_client, org_a):
        """Invalid color should default to blue."""
        response = admin_client.post(
            self.url,
            {"name": "Invalid Color Tag", "color": "neon"},
            format="json",
        )
        assert response.status_code == status.HTTP_201_CREATED
        assert response.data["tag"]["color"] == "blue"

    def test_create_tag_with_description(self, admin_client, org_a):
        """Create a tag with description."""
        response = admin_client.post(
            self.url,
            {"name": "Described Tag", "description": "A tag with description"},
            format="json",
        )
        assert response.status_code == status.HTTP_201_CREATED
        assert response.data["tag"]["description"] == "A tag with description"

    def test_list_tags_excludes_archived(self, admin_client, org_a):
        """Archived tags are not returned by default."""
        Tags.objects.create(name="Active Tag", slug="active-tag", org=org_a)
        Tags.objects.create(
            name="Archived Tag", slug="archived-tag", org=org_a, is_active=False
        )
        response = admin_client.get(self.url)
        assert response.status_code == status.HTTP_200_OK
        assert response.data["tags_count"] == 1

    def test_list_tags_include_archived(self, admin_client, org_a):
        """Archived tags are included when include_archived=true."""
        Tags.objects.create(name="Active Tag2", slug="active-tag2", org=org_a)
        Tags.objects.create(
            name="Archived Tag2", slug="archived-tag2", org=org_a, is_active=False
        )
        response = admin_client.get(self.url + "?include_archived=true")
        assert response.status_code == status.HTTP_200_OK
        assert response.data["tags_count"] == 2

    def test_list_tags_filter_by_name(self, admin_client, org_a):
        """Filter tags by name."""
        Tags.objects.create(name="Priority", slug="priority", org=org_a)
        Tags.objects.create(name="Urgent", slug="urgent", org=org_a)
        response = admin_client.get(self.url + "?name=Pri")
        assert response.status_code == status.HTTP_200_OK
        assert response.data["tags_count"] == 1


@pytest.mark.django_db
class TestTagsUsageAndTotals:
    """The settings/macros analytics: per-tag usage counts and the stat totals."""

    url = "/api/tags/"

    def test_usage_counts_per_model(self, admin_client, org_a):
        tag = Tags.objects.create(name="Renewal", slug="renewal", org=org_a)
        a = Account.objects.create(org=org_a, name="Acme")
        a.tags.add(tag)
        for _ in range(2):
            Lead.objects.create(org=org_a).tags.add(tag)
        Opportunity.objects.create(org=org_a, name="Deal").tags.add(tag)
        Case.objects.create(
            org=org_a, name="Ticket", status="New", priority="Normal"
        ).tags.add(tag)
        Contact.objects.create(
            org=org_a, first_name="Dana", last_name="Client"
        ).tags.add(tag)
        Task.objects.create(
            org=org_a, title="Follow up", status="New", priority="Medium"
        ).tags.add(tag)

        response = admin_client.get(self.url)
        assert response.status_code == status.HTTP_200_OK
        row = _tag_row(response, tag.id)
        assert row["usage"] == {
            "accounts": 1,
            "leads": 2,
            "opportunities": 1,
            "cases": 1,
            "contacts": 1,
            "tasks": 1,
            "api_settings": 0,
            "solutions": 0,
            "web_forms": 0,
            "lead_intakes": 0,
            "macros": 0,
            "projects": 0,
        }

    def test_unused_tag_reports_zero_usage(self, admin_client, org_a):
        tag = Tags.objects.create(name="Lonely", slug="lonely", org=org_a)
        row = _tag_row(admin_client.get(self.url), tag.id)
        assert row["usage"] == {
            "accounts": 0,
            "leads": 0,
            "opportunities": 0,
            "cases": 0,
            "contacts": 0,
            "tasks": 0,
            "api_settings": 0,
            "solutions": 0,
            "web_forms": 0,
            "lead_intakes": 0,
            "macros": 0,
            "projects": 0,
        }

    @pytest.mark.parametrize("kind", ["contacts", "tasks", "api_settings", "solutions"])
    def test_a_tag_used_only_off_the_headline_models_is_not_unused(
        self, admin_client, org_a, kind
    ):
        """The bug: `_TAGGABLE` held four of the seven taggable models.

        A tag applied only to a contact, a task or an API setting reported zero
        usage everywhere and was counted in the "unused" stat, telling an admin
        it was safe to archive while it was in active use.
        """
        tag = Tags.objects.create(name=f"Only {kind}", slug=f"only-{kind}", org=org_a)
        if kind == "contacts":
            Contact.objects.create(
                org=org_a, first_name="Dana", last_name="Client"
            ).tags.add(tag)
        elif kind == "tasks":
            Task.objects.create(
                org=org_a, title="Follow up", status="New", priority="Medium"
            ).tags.add(tag)
        elif kind == "solutions":
            Solution.objects.create(
                org=org_a, title="Resetting your password", description="..."
            ).tags.add(tag)
        else:
            APISettings.objects.create(
                org=org_a, title="Site", website="https://example.com"
            ).tags.add(tag)

        body = admin_client.get(self.url).data
        assert _tag_row_by_id(body, tag.id)["usage"][kind] == 1
        assert body["totals"]["unused"] == 0, (
            f"a tag in use on {kind} was reported as unused"
        )

    def test_taggable_covers_every_model_with_a_tags_m2m(self):
        """Guard the registry's `tags_key` and the hand-written holder list with
        the live model registry.

        Without this, the next model to grow a `tags` M2M silently repeats the
        bug above: it is in neither, so its usage is never counted.
        """
        from django.apps import apps

        from common.object_registry import BUILT_IN
        from common.views.tags_views import NON_OBJECT_TAG_HOLDERS

        declared = {
            model
            for model in apps.get_models()
            for field in model._meta.get_fields()
            if field.many_to_many
            and not field.auto_created
            and getattr(field, "related_model", None) is Tags
        }
        entries = {entry.model for entry in BUILT_IN if entry.tags_key}
        holders = {model for _, _, model in NON_OBJECT_TAG_HOLDERS}
        assert declared == entries | holders, (
            "these models carry a tags M2M but their usage is never counted, so "
            f"a tag used only on them reads as unused: {declared - entries - holders}"
        )
        assert not entries & holders, "a model in both would be counted twice"

    def test_usage_labels_name_every_key(self, monkeypatch, admin_client, org_a):
        _hook(monkeypatch, SliceEntry("obj:site", "Sites", Account, "name", "Site"))
        tag = Tags.objects.create(name="Vip", slug="vip", org=org_a)
        Tags.objects.create(name="Spare", slug="spare", org=org_a)
        for name in ("Site one", "Acme"):
            Account.objects.create(org=org_a, name=name).tags.add(tag)

        body = admin_client.get(self.url).json()
        labels = body["usage_labels"]
        assert list(labels.items()) == [
            ("leads", "Leads"),
            ("contacts", "Contacts"),
            ("accounts", "Accounts"),
            ("opportunities", "Deals"),
            ("cases", "Tickets"),
            ("tasks", "Tasks"),
            ("projects", "Projects"),
            ("obj:site", "Sites"),
            ("api_settings", "API keys"),
            ("solutions", "Articles"),
            ("web_forms", "Web forms"),
            ("lead_intakes", "Lead webhooks"),
            ("macros", "Macros"),
        ]
        assert len(body["tags"]) == 2
        for row in body["tags"]:
            assert list(row["usage"]) == list(labels)
        usage = _tag_row_by_id(body, tag.id)["usage"]
        assert (usage["accounts"], usage["obj:site"]) == (2, 1)

        set_modules_off(org_a, "tickets", "projects")
        body = admin_client.get(self.url).json()
        assert not {"cases", "macros", "projects"} & set(body["usage_labels"])
        assert "obj:site" in body["usage_labels"]
        for row in body["tags"]:
            assert list(row["usage"]) == list(body["usage_labels"])

    def test_totals_count_active_unused(self, admin_client, org_a):
        used = Tags.objects.create(name="Used", slug="used", org=org_a)
        Account.objects.create(org=org_a, name="Acme").tags.add(used)
        Tags.objects.create(name="Lonely", slug="lonely", org=org_a)  # active, unused
        Tags.objects.create(
            name="Archived", slug="archived", org=org_a, is_active=False
        )
        totals = admin_client.get(self.url).data["totals"]
        # count spans archived too; active excludes it; unused = active w/ 0 usage.
        assert totals == {"count": 3, "active": 2, "unused": 1}

    def test_usage_excludes_other_orgs_records(self, admin_client, org_a, org_b):
        """The usage subquery is explicitly org-scoped, so a foreign-org record
        carrying the same tag row is not counted. Proven here on SQLite where
        RLS is inert, so only the ORM filter can be doing the scoping."""
        tag = Tags.objects.create(name="Shared", slug="shared", org=org_a)
        Account.objects.create(org=org_a, name="Ours").tags.add(tag)
        # Attach the SAME tag row to an org_b account (DB allows it).
        Account.objects.create(org=org_b, name="Theirs").tags.add(tag)

        row = _tag_row(admin_client.get(self.url), tag.id)
        assert row["usage"]["accounts"] == 1  # not 2

    def test_totals_isolated_across_orgs(self, org_b_client, org_a):
        # A tag in org_a must not appear in org_b's list or totals.
        Tags.objects.create(name="OrgA only", slug="orga-only", org=org_a)
        data = org_b_client.get(self.url).data
        assert data["totals"]["count"] == 0
        assert data["tags"] == []


@pytest.mark.django_db
class TestTagsDetailView:
    """Tests for GET/PUT/DELETE /api/tags/<pk>/ and POST /api/tags/<pk>/restore/"""

    def _url(self, pk):
        return f"/api/tags/{pk}/"

    def _restore_url(self, pk):
        return f"/api/tags/{pk}/restore/"

    def test_get_tag(self, admin_client, org_a):
        tag = Tags.objects.create(name="Feature", slug="feature", org=org_a)
        response = admin_client.get(self._url(tag.pk))
        assert response.status_code == status.HTTP_200_OK
        assert "tag" in response.data

    def test_update_tag(self, admin_client, org_a):
        tag = Tags.objects.create(name="Old Tag", slug="old-tag", org=org_a)
        response = admin_client.put(
            self._url(tag.pk),
            {"name": "New Tag"},
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False
        assert response.data["tag"]["name"] == "New Tag"

    def test_soft_delete_tag(self, admin_client, org_a):
        tag = Tags.objects.create(name="Deletable", slug="deletable", org=org_a)
        response = admin_client.delete(self._url(tag.pk))
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False
        # Tag still exists in the database but is inactive
        tag.refresh_from_db()
        assert tag.is_active is False

    def test_restore_tag(self, admin_client, org_a):
        tag = Tags.objects.create(
            name="Archived", slug="archived", org=org_a, is_active=False
        )
        response = admin_client.post(self._restore_url(tag.pk), format="json")
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False
        tag.refresh_from_db()
        assert tag.is_active is True

    def test_get_tag_not_found(self, admin_client, org_a):
        """Getting a non-existent tag returns 404."""
        import uuid

        fake_id = uuid.uuid4()
        response = admin_client.get(self._url(fake_id))
        assert response.status_code == status.HTTP_404_NOT_FOUND

    def test_update_tag_duplicate_name(self, admin_client, org_a):
        """Updating a tag to a name that already exists should fail."""
        Tags.objects.create(name="Existing", slug="existing", org=org_a)
        tag = Tags.objects.create(name="To Update", slug="to-update", org=org_a)
        response = admin_client.put(
            self._url(tag.pk),
            {"name": "Existing"},
            format="json",
        )
        assert response.status_code == status.HTTP_400_BAD_REQUEST

    def test_update_tag_empty_name(self, admin_client, org_a):
        """Updating a tag with empty name should fail."""
        tag = Tags.objects.create(name="Empty Update", slug="empty-update", org=org_a)
        response = admin_client.put(
            self._url(tag.pk),
            {"name": ""},
            format="json",
        )
        assert response.status_code == status.HTTP_400_BAD_REQUEST

    def test_update_tag_non_admin_forbidden(self, user_client, org_a):
        """Non-admin user cannot update tags."""
        tag = Tags.objects.create(name="Admin Only", slug="admin-only", org=org_a)
        response = user_client.put(
            self._url(tag.pk),
            {"name": "Not Allowed"},
            format="json",
        )
        assert response.status_code == status.HTTP_403_FORBIDDEN

    def test_delete_tag_non_admin_forbidden(self, user_client, org_a):
        """Non-admin user cannot archive tags."""
        tag = Tags.objects.create(name="No Delete", slug="no-delete", org=org_a)
        response = user_client.delete(self._url(tag.pk))
        assert response.status_code == status.HTTP_403_FORBIDDEN

    def test_restore_tag_non_admin_forbidden(self, user_client, org_a):
        """Non-admin user cannot restore tags."""
        tag = Tags.objects.create(
            name="No Restore", slug="no-restore", org=org_a, is_active=False
        )
        response = user_client.post(self._restore_url(tag.pk), format="json")
        assert response.status_code == status.HTTP_403_FORBIDDEN

    def test_update_tag_not_found(self, admin_client, org_a):
        """Updating non-existent tag returns 404."""
        import uuid

        fake_id = uuid.uuid4()
        response = admin_client.put(
            self._url(fake_id),
            {"name": "Ghost Tag"},
            format="json",
        )
        assert response.status_code == status.HTTP_404_NOT_FOUND

    def test_delete_tag_not_found(self, admin_client, org_a):
        """Archiving non-existent tag returns 404."""
        import uuid

        fake_id = uuid.uuid4()
        response = admin_client.delete(self._url(fake_id))
        assert response.status_code == status.HTTP_404_NOT_FOUND

    def test_restore_tag_not_found(self, admin_client, org_a):
        """Restoring non-existent tag returns 404."""
        import uuid

        fake_id = uuid.uuid4()
        response = admin_client.post(self._restore_url(fake_id), format="json")
        assert response.status_code == status.HTTP_404_NOT_FOUND

    def test_update_tag_with_color(self, admin_client, org_a):
        """Update tag color."""
        tag = Tags.objects.create(name="Color Tag", slug="color-tag", org=org_a)
        response = admin_client.put(
            self._url(tag.pk),
            {"name": "Color Tag", "color": "green"},
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK
        assert response.data["tag"]["color"] == "green"

    def test_update_tag_with_description(self, admin_client, org_a):
        """Update tag description."""
        tag = Tags.objects.create(name="Desc Tag", slug="desc-tag", org=org_a)
        response = admin_client.put(
            self._url(tag.pk),
            {"name": "Desc Tag", "description": "Updated description"},
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK


@pytest.mark.django_db
class TestTagsMergeView:
    """POST /api/tags/<pk>/merge/ with `{"into": <tag id>}`.

    The settings page has shown a "these two look like the same tag" banner
    since it was built, with a Merge button wired to nothing because this
    endpoint did not exist.
    """

    def _url(self, pk):
        return f"/api/tags/{pk}/merge/"

    def _pair(self, org):
        source = Tags.objects.create(name="Invoices", slug="invoices", org=org)
        target = Tags.objects.create(name="Invoice", slug="invoice", org=org)
        return source, target

    def test_merge_moves_records_across_every_taggable_model(self, admin_client, org_a):
        """Every taggable model, not just the prominent four.

        The same list that under-counted usage decides what a merge walks,
        so a model missing from it would keep the source tag after the source
        was archived: a tag applied to records but invisible in the UI.
        """
        source, target = self._pair(org_a)
        account = Account.objects.create(org=org_a, name="Acme")
        lead = Lead.objects.create(org=org_a)
        deal = Opportunity.objects.create(org=org_a, name="Deal")
        case = Case.objects.create(
            org=org_a, name="Ticket", status="New", priority="Normal"
        )
        contact = Contact.objects.create(
            org=org_a, first_name="Dana", last_name="Client"
        )
        task = Task.objects.create(
            org=org_a, title="Follow up", status="New", priority="Medium"
        )
        setting = APISettings.objects.create(
            org=org_a, title="Site", website="https://example.com"
        )
        records = [account, lead, deal, case, contact, task, setting]
        for record in records:
            record.tags.add(source)

        response = admin_client.post(
            self._url(source.pk), {"into": str(target.pk)}, format="json"
        )

        assert response.status_code == status.HTTP_200_OK
        assert response.data["moved"] == len(records)
        for record in records:
            tags = set(record.tags.all())
            assert target in tags, f"{type(record).__name__} did not get the target tag"
            assert source not in tags, f"{type(record).__name__} kept the source tag"

    def test_merge_moves_each_model_once(self, monkeypatch, admin_client, org_a):
        """Two hook entries share a model only they cover. The merge walks that
        model once, rows in neither entry (say, an archived object's) included,
        and counts each row once."""
        monkeypatch.setattr(
            tags_views,
            "NON_OBJECT_TAG_HOLDERS",
            tuple(
                h for h in tags_views.NON_OBJECT_TAG_HOLDERS if h[2] is not APISettings
            ),
        )
        _hook(
            monkeypatch,
            SliceEntry("obj:north", "North sites", APISettings, "title", "North"),
            SliceEntry("obj:south", "South sites", APISettings, "title", "South"),
        )
        source, target = self._pair(org_a)
        rows = [
            APISettings.objects.create(
                org=org_a, title=title, website="https://example.com"
            )
            for title in ("North 1", "South 1", "Archived 1")
        ]
        for row in rows:
            row.tags.add(source)
        table = f'FROM "{APISettings._meta.db_table}"'

        with CaptureQueriesContext(connection) as queries:
            response = admin_client.post(
                self._url(source.pk), {"into": str(target.pk)}, format="json"
            )

        assert response.status_code == status.HTTP_200_OK
        assert response.data["moved"] == 3
        for row in rows:
            assert set(row.tags.all()) == {target}
        walks = [
            q["sql"]
            for q in queries
            if q["sql"].startswith("SELECT") and table in q["sql"]
        ]
        assert len(walks) == 1

    def test_merge_moves_records_of_a_switched_off_module(self, admin_client, org_a):
        """The source is archived, so a ticket left on it would come back with
        Tickets carrying a tag the settings page shows as off."""
        set_modules_off(org_a, "tickets")
        source, target = self._pair(org_a)
        case = Case.objects.create(
            org=org_a, name="Ticket", status="New", priority="Normal"
        )
        case.tags.add(source)

        response = admin_client.post(
            self._url(source.pk), {"into": str(target.pk)}, format="json"
        )

        assert response.data["moved"] == 1
        assert list(case.tags.all()) == [target]

    def test_merge_archives_the_source_rather_than_deleting_it(
        self, admin_client, org_a
    ):
        """Nothing hard-deletes a tag anywhere in this module, and a merge is
        where that matters most: if it was a mistake, the name survives."""
        source, target = self._pair(org_a)
        response = admin_client.post(
            self._url(source.pk), {"into": str(target.pk)}, format="json"
        )
        assert response.status_code == status.HTTP_200_OK
        source.refresh_from_db()
        assert source.is_active is False
        assert Tags.objects.filter(pk=source.pk).exists()

    def test_a_record_carrying_both_tags_is_not_double_counted(
        self, admin_client, org_a
    ):
        source, target = self._pair(org_a)
        account = Account.objects.create(org=org_a, name="Both")
        account.tags.add(source, target)

        response = admin_client.post(
            self._url(source.pk), {"into": str(target.pk)}, format="json"
        )

        assert response.data["moved"] == 1
        assert list(account.tags.all()) == [target]

    def test_merge_leaves_records_on_other_tags_alone(self, admin_client, org_a):
        source, target = self._pair(org_a)
        bystander = Tags.objects.create(name="Urgent", slug="urgent", org=org_a)
        account = Account.objects.create(org=org_a, name="Acme")
        account.tags.add(source, bystander)

        admin_client.post(self._url(source.pk), {"into": str(target.pk)}, format="json")

        assert set(account.tags.all()) == {target, bystander}

    # Authorization

    def test_non_admin_cannot_merge(self, user_client, org_a):
        source, target = self._pair(org_a)
        account = Account.objects.create(org=org_a, name="Acme")
        account.tags.add(source)

        response = user_client.post(
            self._url(source.pk), {"into": str(target.pk)}, format="json"
        )

        assert response.status_code == status.HTTP_403_FORBIDDEN
        assert list(account.tags.all()) == [source]
        source.refresh_from_db()
        assert source.is_active is True

    def test_unauthenticated_cannot_merge(self, unauthenticated_client, org_a):
        source, target = self._pair(org_a)
        response = unauthenticated_client.post(
            self._url(source.pk), {"into": str(target.pk)}, format="json"
        )
        assert response.status_code in (
            status.HTTP_401_UNAUTHORIZED,
            status.HTTP_403_FORBIDDEN,
        )

    # Tenancy

    def test_cannot_merge_into_another_orgs_tag(self, admin_client, org_a, org_b):
        """The crown-jewel case: `into` comes from the request body.

        Without the org filter on that lookup, an admin could stamp another
        tenant's tag row onto their own records, and the foreign org's tag
        list would start reporting usage it cannot see. Proven on SQLite,
        where RLS is inert, so only the ORM filter can be doing the scoping.
        """
        source = Tags.objects.create(name="Ours", slug="ours", org=org_a)
        theirs = Tags.objects.create(name="Theirs", slug="theirs", org=org_b)
        account = Account.objects.create(org=org_a, name="Acme")
        account.tags.add(source)

        response = admin_client.post(
            self._url(source.pk), {"into": str(theirs.pk)}, format="json"
        )

        assert response.status_code == status.HTTP_404_NOT_FOUND
        assert list(account.tags.all()) == [source]
        source.refresh_from_db()
        assert source.is_active is True

    def test_cannot_merge_another_orgs_tag(self, admin_client, org_a, org_b):
        theirs = Tags.objects.create(name="Theirs", slug="theirs", org=org_b)
        target = Tags.objects.create(name="Ours", slug="ours", org=org_a)

        response = admin_client.post(
            self._url(theirs.pk), {"into": str(target.pk)}, format="json"
        )

        assert response.status_code == status.HTTP_404_NOT_FOUND
        theirs.refresh_from_db()
        assert theirs.is_active is True

    def test_merge_only_moves_this_orgs_records(self, admin_client, org_a, org_b):
        """A tag row can be attached to a foreign org's record at the DB level.

        The merge loop filters by org for the same reason the usage subquery
        does, so a record in another org keeps whatever it had.
        """
        source, target = self._pair(org_a)
        ours = Account.objects.create(org=org_a, name="Ours")
        theirs = Account.objects.create(org=org_b, name="Theirs")
        ours.tags.add(source)
        theirs.tags.add(source)

        response = admin_client.post(
            self._url(source.pk), {"into": str(target.pk)}, format="json"
        )

        assert response.data["moved"] == 1
        assert list(ours.tags.all()) == [target]
        assert list(theirs.tags.all()) == [source]

    # Validation

    def test_missing_into_is_400(self, admin_client, org_a):
        source, _target = self._pair(org_a)
        response = admin_client.post(self._url(source.pk), {}, format="json")
        assert response.status_code == status.HTTP_400_BAD_REQUEST
        assert "into" in response.data["errors"]

    def test_merging_a_tag_into_itself_is_400(self, admin_client, org_a):
        source, _target = self._pair(org_a)
        response = admin_client.post(
            self._url(source.pk), {"into": str(source.pk)}, format="json"
        )
        assert response.status_code == status.HTTP_400_BAD_REQUEST
        source.refresh_from_db()
        assert source.is_active is True

    def test_merging_onto_an_archived_tag_is_400(self, admin_client, org_a):
        """Validate the destination state, not just that it resolves.

        Merging onto an archived tag hides every moved record behind a tag the
        settings page renders as "Off", which reads as data loss.
        """
        source, target = self._pair(org_a)
        target.is_active = False
        target.save()
        account = Account.objects.create(org=org_a, name="Acme")
        account.tags.add(source)

        response = admin_client.post(
            self._url(source.pk), {"into": str(target.pk)}, format="json"
        )

        assert response.status_code == status.HTTP_400_BAD_REQUEST
        assert list(account.tags.all()) == [source]

    def test_merging_an_archived_source_is_allowed(self, admin_client, org_a):
        """The reverse is fine: cleaning up an archived duplicate that still
        carries records is exactly what this endpoint is for."""
        source, target = self._pair(org_a)
        source.is_active = False
        source.save()
        account = Account.objects.create(org=org_a, name="Acme")
        account.tags.add(source)

        response = admin_client.post(
            self._url(source.pk), {"into": str(target.pk)}, format="json"
        )

        assert response.status_code == status.HTTP_200_OK
        assert list(account.tags.all()) == [target]

    def test_unknown_into_is_404(self, admin_client, org_a):
        import uuid

        source, _target = self._pair(org_a)
        response = admin_client.post(
            self._url(source.pk), {"into": str(uuid.uuid4())}, format="json"
        )
        assert response.status_code == status.HTTP_404_NOT_FOUND

    def test_malformed_into_is_404_not_500(self, admin_client, org_a):
        """`into` is a client-supplied string. A non-UUID used to be the shape
        that reached the DB and raised, which is the malformed-id 500 class."""
        source, _target = self._pair(org_a)
        response = admin_client.post(
            self._url(source.pk), {"into": "banana"}, format="json"
        )
        assert response.status_code == status.HTTP_404_NOT_FOUND

    def test_unknown_source_is_404(self, admin_client, org_a):
        import uuid

        _source, target = self._pair(org_a)
        response = admin_client.post(
            self._url(uuid.uuid4()), {"into": str(target.pk)}, format="json"
        )
        assert response.status_code == status.HTTP_404_NOT_FOUND
