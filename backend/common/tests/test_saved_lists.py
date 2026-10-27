"""Saved views read their lists from the object registry.

Run with: pytest common/tests/test_saved_lists.py -v
"""

from dataclasses import dataclass

import pytest

from common import object_registry
from common.models import Document, SavedView
from common.modules import module_off_message
from common.object_registry import BUILT_IN, all_objects
from common.saved_views import SavedList, saved_lists
from common.testing import set_modules_off
from common.validators import uuid_list_param

URL = "/api/saved-views/"


def detail(pk):
    return f"{URL}{pk}/"


def create(client, **body):
    payload = {"module": "leads", "name": "Hot", "filters": {}}
    payload.update(body)
    return client.post(URL, payload, format="json")


def test_saved_lists_come_from_the_registry(org_a):
    lists = saved_lists(org_a)
    assert list(lists) == [
        "leads",
        "contacts",
        "accounts",
        "opportunities",
        "cases",
        "invoices",
    ]
    assert [e.key for e in BUILT_IN if e.saved_list() is not None] == [
        "lead",
        "contact",
        "account",
        "deal",
        "ticket",
        "invoice",
    ]
    for entry in all_objects(org_a):
        spec = entry.saved_list()
        if spec is not None:
            assert isinstance(spec, SavedList)
            assert lists[spec.name] is spec
    field = SavedView._meta.get_field("module")
    assert field.max_length == 40
    assert not field.choices


def test_views_on_an_unavailable_list_are_hidden_and_kept(user_client, org_a):
    deals = create(
        user_client,
        module="opportunities",
        name="Big deals",
        filters={"amount__gte": "1000"},
    )
    assert deals.status_code == 201, deals.data
    assert create(user_client, module="leads", name="Hot").status_code == 201

    set_modules_off(org_a, "deals")
    assert "opportunities" not in saved_lists(org_a)
    listed = user_client.get(URL).json()["saved_views"]
    assert [v["name"] for v in listed] == ["Hot"]
    assert user_client.get(URL, {"module": "opportunities"}).json() == {
        "saved_views": [],
        "limit": 25,
    }
    assert user_client.get(detail(deals.data["id"])).status_code == 404
    refused = create(user_client, module="opportunities", name="Another")
    assert refused.status_code == 400
    assert refused.json() == {"module": [module_off_message(org_a, "deals")]}
    stored = SavedView.objects.get(pk=deals.data["id"])
    assert stored.filters == {"amount__gte": ["1000"]}

    org_a.modules_off = []
    org_a.save(update_fields=["modules_off"])
    listed = user_client.get(URL).json()["saved_views"]
    assert sorted(v["name"] for v in listed) == ["Big deals", "Hot"]
    assert user_client.get(detail(deals.data["id"])).status_code == 200


def _site_rows(profile, params):
    rows = Document.objects.filter(org=profile.org)
    if params.get("q"):
        rows = rows.filter(title__icontains=params.get("q"))
    assigned_to = uuid_list_param(params, "assigned_to")
    if assigned_to:
        rows = rows.filter(pk__in=assigned_to)
    return rows


SITE_LIST = SavedList(
    name="obj:site", query=_site_rows, params=frozenset({"q", "assigned_to"})
)


@dataclass(frozen=True)
class SiteEntry:
    key: str = "obj:site"
    custom_field_target: str = "obj:site"
    label: str = "Site"
    label_plural: str = "Sites"

    def saved_list(self):
        return SITE_LIST


def test_a_hook_entry_list_accepts_views(monkeypatch, user_client, org_a, org_b_client):
    monkeypatch.setattr(
        object_registry,
        "_HOOKS",
        [lambda org: (SiteEntry(),) if org is not None and org.pk == org_a.pk else ()],
    )
    assert saved_lists(org_a)["obj:site"] is SITE_LIST

    created = create(
        user_client,
        module="obj:site",
        name="North",
        filters={"q": "north", "cf_region": "EMEA"},
    )
    assert created.status_code == 201, created.data
    assert created.data["filters"] == {"q": ["north"], "cf_region": ["EMEA"]}
    view_id = created.data["id"]
    listed = user_client.get(URL, {"module": "obj:site"}).json()["saved_views"]
    assert [v["id"] for v in listed] == [view_id]
    assert user_client.get(detail(view_id)).status_code == 200

    # The entry's own parameters bound what a view holds, and its query parses them.
    unknown = create(user_client, module="obj:site", name="X", filters={"status": "a"})
    assert unknown.status_code == 400
    assert unknown.json() == {"filters": ["This list does not filter by: status."]}
    malformed = create(
        user_client, module="obj:site", name="Y", filters={"assigned_to": "nope"}
    )
    assert malformed.status_code == 400
    assert malformed.json() == {"filters": ["assigned_to: 'nope' is not a valid id."]}

    # Another org has no such list.
    elsewhere = create(org_b_client, module="obj:site", name="North")
    assert elsewhere.status_code == 400
    assert elsewhere.json() == {"module": ['"obj:site" is not a valid choice.']}

    # The entry gone (its object archived): hidden, kept.
    monkeypatch.setattr(object_registry, "_HOOKS", [])
    assert user_client.get(URL).json()["saved_views"] == []
    assert user_client.get(detail(view_id)).status_code == 404
    assert user_client.get(URL, {"module": "obj:site"}).status_code == 400
    assert SavedView.objects.filter(pk=view_id, module="obj:site").exists()


@pytest.mark.parametrize("module", ["tasks", "obj:ghost", "x" * 41])
def test_a_list_the_org_does_not_have_is_refused(user_client, module):
    response = create(user_client, module=module)
    assert response.status_code == 400
    assert "module" in response.json()
    assert not SavedView.objects.exists()
