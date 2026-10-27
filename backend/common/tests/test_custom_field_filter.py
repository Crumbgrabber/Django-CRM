"""``cf_<key>`` list filters are typed by the field and run on SQLite too.

Run with: pytest common/tests/test_custom_field_filter.py -v
"""

import pytest
from django.http import QueryDict

from cases.models import CaseWatcher
from common.custom_fields import custom_field_filter
from common.models import CustomFieldDefinition
from common.tests.object_records import make_record
from leads.models import Lead


def _field(org, key, field_type, target="Lead", **extra):
    return CustomFieldDefinition.objects.create(
        org=org,
        target_model=target,
        key=key,
        label=key.title(),
        field_type=field_type,
        **extra,
    )


def _lead(org, **custom_fields):
    return Lead.objects.create(title="Lead", org=org, custom_fields=custom_fields)


def _matching(org, query, target="Lead"):
    condition = custom_field_filter(target, org, QueryDict(query))
    return set(
        Lead.objects.filter(org=org).filter(condition).values_list("pk", flat=True)
    )


def test_number_filter_matches_stored_float(org_a):
    _field(org_a, "bedrooms", "number")
    three = _lead(org_a, bedrooms=3.0)
    _lead(org_a, bedrooms=4.0)
    _lead(org_a)
    for raw in ("3", "3.0", "3.00"):
        assert _matching(org_a, f"cf_bedrooms={raw}") == {three.pk}, raw


@pytest.mark.parametrize("raw", ["three", "nan", "inf", "1e999"])
def test_bad_number_is_400_naming_the_field(admin_client, org_a, raw):
    _field(org_a, "bedrooms", "number")
    _lead(org_a, bedrooms=3.0)
    response = admin_client.get("/api/leads/", {"cf_bedrooms": raw})
    assert response.status_code == 400
    assert response.json() == {"cf_bedrooms": ["must be a number"]}


def test_checkbox_filter_true_and_false(org_a):
    _field(org_a, "pets", "checkbox")
    yes = _lead(org_a, pets=True)
    no = _lead(org_a, pets=False)
    _lead(org_a)
    assert _matching(org_a, "cf_pets=true") == {yes.pk}
    assert _matching(org_a, "cf_pets=false") == {no.pk}
    assert _matching(org_a, "cf_pets=yes") == {yes.pk}
    assert _matching(org_a, "cf_pets=0") == {no.pk}


def test_date_dropdown_and_text_filters_match_exactly(org_a):
    _field(org_a, "move_in", "date")
    _field(
        org_a,
        "tier",
        "dropdown",
        options=[{"value": "gold", "label": "Gold"}, {"value": "tin", "label": "Tin"}],
    )
    _field(org_a, "note", "text")
    match = _lead(org_a, move_in="2026-11-02", tier="gold", note="Corner")
    _lead(org_a, move_in="2026-11-03", tier="tin", note="corner")
    assert _matching(org_a, "cf_move_in=2026-11-02") == {match.pk}
    assert _matching(org_a, "cf_tier=gold") == {match.pk}
    assert _matching(org_a, "cf_note=Corner") == {match.pk}
    assert _matching(org_a, "cf_move_in=2026-11-02&cf_tier=tin") == set()


def test_bad_date_and_checkbox_are_400_naming_each_field(admin_client, org_a):
    _field(org_a, "move_in", "date")
    _field(org_a, "pets", "checkbox")
    response = admin_client.get(
        "/api/leads/", {"cf_move_in": "2026-02-30", "cf_pets": "maybe"}
    )
    assert response.status_code == 400
    assert response.json() == {
        "cf_move_in": ["must be a YYYY-MM-DD date"],
        "cf_pets": ["must be a boolean"],
    }


def test_inactive_field_filter_is_ignored(admin_client, org_a):
    _field(org_a, "bedrooms", "number", is_active=False)
    three = _lead(org_a, bedrooms=3.0)
    four = _lead(org_a, bedrooms=4.0)
    assert _matching(org_a, "cf_bedrooms=3") == {three.pk, four.pk}
    # Ignored before parsing, so a value the old field would refuse is no 400.
    response = admin_client.get("/api/leads/", {"cf_bedrooms": "three"})
    assert response.status_code == 200
    # A key no field has is ignored the same way, and so is a blank value.
    assert _matching(org_a, "cf_ghost=1&cf_=x") == {three.pk, four.pk}
    _field(org_a, "rooms", "number")
    assert _matching(org_a, "cf_rooms=") == {three.pk, four.pk}


def test_another_targets_or_orgs_field_is_ignored(org_a, org_b):
    _field(org_a, "bedrooms", "number", target="Contact")
    _field(org_b, "bedrooms", "number")
    three = _lead(org_a, bedrooms=3.0)
    four = _lead(org_a, bedrooms=4.0)
    assert _matching(org_a, "cf_bedrooms=3") == {three.pk, four.pk}


def test_double_underscore_key_is_not_a_lookup(org_a):
    _field(org_a, "rooms__gte", "number")
    exact = _lead(org_a, rooms__gte=3.0)
    # Read as a lookup path, `rooms__gte=3` would match this one instead.
    _lead(org_a, rooms=10.0)
    assert _matching(org_a, "cf_rooms__gte=3") == {exact.pk}


def test_no_custom_field_parameter_costs_no_query(org_a, django_assert_num_queries):
    with django_assert_num_queries(0):
        assert not custom_field_filter("Lead", org_a, QueryDict("status=new"))


# One number filter on every built-in list. `ids` names the list.
LISTS = [
    ("lead", "Lead", "/api/leads/"),
    ("contact", "Contact", "/api/contacts/"),
    ("account", "Account", "/api/accounts/"),
    ("deal", "Opportunity", "/api/opportunities/"),
    ("ticket", "Case", "/api/cases/"),
    ("ticket", "Case", "/api/cases/watching/"),
    ("task", "Task", "/api/tasks/"),
    ("invoice", "Invoice", "/api/invoices/"),
    ("estimate", "Estimate", "/api/invoices/estimates/"),
    ("recurring_invoice", "RecurringInvoice", "/api/invoices/recurring/"),
]


@pytest.mark.parametrize(("key", "target", "url"), LISTS, ids=[u for *_, u in LISTS])
def test_every_built_in_list_uses_the_typed_filter(
    admin_client, admin_profile, admin_user, org_a, key, target, url
):
    _field(org_a, "size", "number", target=target)
    three = make_record(key, org_a, admin_user)
    four = make_record(key, org_a, admin_user)
    for record, size in ((three, 3.0), (four, 4.0)):
        type(record).objects.filter(pk=record.pk).update(custom_fields={"size": size})
        if key == "ticket":
            type(record).objects.filter(pk=record.pk).update(priority="Normal")
            CaseWatcher.objects.create(case=record, profile=admin_profile, org=org_a)

    response = admin_client.get(url, {"cf_size": "3"})
    assert response.status_code == 200, response.content
    body = response.content.decode()
    assert str(three.pk) in body
    assert str(four.pk) not in body
    assert admin_client.get(url, {"cf_size": "three"}).json() == {
        "cf_size": ["must be a number"]
    }


@pytest.mark.parametrize("field_type", ["text", "dropdown"])
def test_nul_in_a_filter_value_is_400_naming_the_field(admin_client, org_a, field_type):
    extra = (
        {"options": [{"value": "a", "label": "A"}]} if field_type == "dropdown" else {}
    )
    _field(org_a, "note", field_type, **extra)
    response = admin_client.get("/api/leads/?cf_note=a%00b")
    assert response.status_code == 400
    assert response.json() == {"cf_note": ["must not contain null characters"]}


def test_nul_in_a_written_value_is_refused(org_a):
    from common.custom_fields import validate_payload

    _field(org_a, "note", "text")
    cleaned, errors = validate_payload("Lead", {"note": "a\x00b"}, org_a)
    assert cleaned == {}
    assert errors == {"note": "must not contain null characters"}


def test_validate_payload_reads_no_definitions_when_given(
    org_a, django_assert_num_queries
):
    from common.custom_fields import validate_payload

    _field(org_a, "note", "text")
    definitions = list(
        CustomFieldDefinition.objects.filter(org=org_a, target_model="Lead")
    )
    with django_assert_num_queries(0):
        cleaned, errors = validate_payload(
            "Lead", {"note": "hi"}, org_a, definitions=definitions
        )
    assert cleaned == {"note": "hi"}
    assert errors == {}
