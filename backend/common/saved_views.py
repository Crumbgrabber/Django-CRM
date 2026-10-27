"""Saved list views (G29): which lists can have one, and what a view may hold.

A saved view is a name and a set of list query parameters, stored per profile
so a person can put a filtered list back with one tap. The lists that take one
come from the object registry: each entry with a ``saved_list()`` names a
:class:`SavedList`, and :func:`saved_lists` gathers them for an org.

**What a view may hold is what its list reads.** A :class:`SavedList` pairs
the function the list view (and its CSV export) builds its queryset with, and
the query parameters that function reads. A view is checked two ways before
it is stored:

* every key is one of those parameters, or a ``cf_<key>`` custom-field filter,
  which every one of these lists takes. Anything else is refused, so a view
  cannot become a place to park arbitrary data;
* the values are handed to that same function, so a malformed id, date or
  number is refused with the list's own 400 now, rather than taking the list
  down every time the view is applied.

The parameter sets are written out rather than discovered, so a change to what
a view can hold shows up in a diff. ``common/tests/test_saved_views.py`` reads
each built-in list function with a recording mapping and fails when the two
disagree, in either direction.
"""

import re
from collections.abc import Callable
from dataclasses import dataclass

from django.db import IntegrityError, transaction
from django.db.models import QuerySet
from django.http import QueryDict
from drf_spectacular.utils import extend_schema_field
from rest_framework import serializers

from accounts.views import account_list_queryset
from cases.views import case_list_queryset
from common.models import Profile, SavedView
from common.modules import module_off_message
from common.object_registry import BUILT_IN, all_objects
from contacts.views import contact_list_queryset
from invoices.api_views import filter_invoices
from invoices.permissions import visible_invoices_qs
from leads.views.lead_views import lead_list_queryset
from opportunity.views.opportunity_views import deal_list_queryset


@dataclass(frozen=True)
class SavedList:
    """A list that takes saved views: its saved-view name, the function that
    builds its rows for a profile and a query string, and the parameters that
    function reads."""

    name: str
    query: Callable[[Profile, QueryDict], QuerySet]
    params: frozenset[str]


MAX_VIEWS_PER_LIST = 25
MAX_PARAMS = 30
MAX_VALUES_PER_PARAM = 50
MAX_VALUE_LENGTH = 200

CUSTOM_FIELD_PARAM = re.compile(r"^cf_[A-Za-z0-9_]{1,100}$")

_DATES = ("created_at__gte", "created_at__lte")

LEAD_LIST = SavedList(
    name="leads",
    query=lead_list_queryset,
    params=frozenset(
        {
            "name",
            "salutation",
            "source",
            "assigned_to",
            "status",
            "tags",
            "city",
            "email",
            "rating",
            "search",
            *_DATES,
            "close_date__gte",
            "close_date__lte",
            "next_follow_up",
            "open",
            "unanswered",
        }
    ),
)

CONTACT_LIST = SavedList(
    name="contacts",
    query=lambda profile, params: contact_list_queryset(profile, params)[1],
    params=frozenset(
        {
            "name",
            "city",
            "phone",
            "email",
            "assigned_to",
            "tags",
            "search",
            *_DATES,
            "is_active",
        }
    ),
)

ACCOUNT_LIST = SavedList(
    name="accounts",
    query=account_list_queryset,
    params=frozenset(
        {
            "name",
            "city",
            "industry",
            "tags",
            "assigned_to",
            "search",
            *_DATES,
            "is_active",
        }
    ),
)

DEAL_LIST = SavedList(
    name="opportunities",
    query=deal_list_queryset,
    params=frozenset(
        {
            "name",
            "account",
            "pipeline",
            "stage",
            "lead_source",
            "tags",
            "assigned_to",
            "search",
            *_DATES,
            "closed_on__gte",
            "closed_on__lte",
            "amount__gte",
            "amount__lte",
            "open",
            "rotten",
        }
    ),
)

TICKET_LIST = SavedList(
    name="cases",
    query=case_list_queryset,
    params=frozenset(
        {
            "include_deleted",
            "show_merged",
            "name",
            "status",
            "priority",
            "account",
            "case_type",
            "assigned_to",
            "tags",
            "search",
            *_DATES,
            "sla_breached",
            "ordering",
        }
    ),
)

INVOICE_LIST = SavedList(
    name="invoices",
    query=lambda profile, params: filter_invoices(
        visible_invoices_qs(profile), params, profile.org
    ),
    params=frozenset(
        {
            "search",
            "status",
            "account",
            "contact",
            "opportunity",
            "assigned_to",
            "created_by",
            "issue_date_gte",
            "issue_date_lte",
            "due_date_gte",
            "due_date_lte",
            "sort",
        }
    ),
)


def saved_lists(org) -> dict[str, SavedList]:
    """The lists ``org`` can keep views on, by name, in registry order.

    An entry whose module is off, or that a hook no longer returns, is left
    out, so its views are hidden from every read but stay stored.
    """
    return {
        spec.name: spec
        for spec in (entry.saved_list() for entry in all_objects(org))
        if spec is not None
    }


def _built_in_list_modules():
    """Each built-in list's name, with the module that can switch it off."""
    return {
        spec.name: entry.module
        for entry in BUILT_IN
        if (spec := entry.saved_list()) is not None
    }


def is_built_in_list(module):
    return module in _built_in_list_modules()


def _unavailable_list_message(org, module):
    """Why ``org`` cannot save a view on ``module``: its module is off, or the
    list is not one of its lists at all (DRF's own choice message, kept from
    when ``module`` was a choice field)."""
    off = _built_in_list_modules().get(module)
    if off is not None:
        return module_off_message(org, off)
    return f'"{module}" is not a valid choice.'


def _clean_filters(spec, value):
    """``value`` as ``{param: [text, ...]}``, or raise with what is wrong.

    A value may arrive as one string or a list of them; blanks are dropped, and
    a parameter left with nothing is dropped with them.
    """
    if not isinstance(value, dict):
        raise serializers.ValidationError("Send the filters as an object.")
    if len(value) > MAX_PARAMS:
        raise serializers.ValidationError(
            f"A view can hold at most {MAX_PARAMS} filters."
        )
    accepted = spec.params
    unknown = sorted(
        str(key)[:50]
        for key in value
        if not isinstance(key, str)
        or (key not in accepted and not CUSTOM_FIELD_PARAM.match(key))
    )
    if unknown:
        raise serializers.ValidationError(
            f"This list does not filter by: {', '.join(unknown[:5])}."
        )
    cleaned = {}
    for key, raw in value.items():
        values = raw if isinstance(raw, list) else [raw]
        if not all(isinstance(v, str) for v in values):
            raise serializers.ValidationError(f"{key}: every value must be text.")
        values = [v.strip() for v in values if v.strip()]
        if len(values) > MAX_VALUES_PER_PARAM:
            raise serializers.ValidationError(
                f"{key}: at most {MAX_VALUES_PER_PARAM} values."
            )
        if any(len(v) > MAX_VALUE_LENGTH for v in values):
            raise serializers.ValidationError(
                f"{key}: a value can be at most {MAX_VALUE_LENGTH} characters."
            )
        if values:
            cleaned[key] = values
    return cleaned


def _check_values(profile, spec, filters):
    """Run the list's own parameter parsing over ``filters``.

    The queryset is built, never evaluated. A malformed id, date or number
    raises the list's own ``ValidationError`` while it is being built.
    """
    params = QueryDict(mutable=True)
    for key, values in filters.items():
        params.setlist(key, values)
    try:
        spec.query(profile, params)
    except serializers.ValidationError as exc:
        # The list names the parameter it refused; kept as one flat sentence
        # per parameter, which is what both clients show.
        detail = exc.detail
        if isinstance(detail, dict):
            detail = [
                f"{key}: {value[0] if isinstance(value, list) else value}"
                for key, value in detail.items()
            ]
        raise serializers.ValidationError({"filters": detail}) from None


@extend_schema_field(
    {
        "type": "object",
        "additionalProperties": {"type": "array", "items": {"type": "string"}},
    }
)
class _FiltersField(serializers.JSONField):
    """Stored as ``_clean_filters`` leaves it: ``{param: [text, ...]}``."""


class SavedViewSerializer(serializers.ModelSerializer):
    """One saved view, as its owner reads and writes it.

    ``org`` and ``profile`` are set by the view from the request, and a body
    naming either is refused rather than ignored. ``module`` is fixed once the
    view exists: a view's filters only mean something to the list they came
    from.
    """

    filters = _FiltersField(required=False)

    class Meta:
        model = SavedView
        fields = ("id", "module", "name", "filters", "created_at", "updated_at")
        read_only_fields = ("id", "created_at", "updated_at")

    def validate_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Give the view a name.")
        return value

    def validate(self, attrs):
        for field in ("org", "profile"):
            if field in self.initial_data:
                raise serializers.ValidationError({field: "This is set by the server."})
        instance = self.instance
        if instance is not None and attrs.get("module", instance.module) != (
            instance.module
        ):
            raise serializers.ValidationError(
                {"module": "A saved view cannot move to another list."}
            )
        module = attrs.get("module") or instance.module
        profile = self.context["request"].profile
        spec = saved_lists(profile.org).get(module)
        if spec is None:
            raise serializers.ValidationError(
                {"module": [_unavailable_list_message(profile.org, module)]}
            )
        if "filters" in attrs:
            try:
                attrs["filters"] = _clean_filters(spec, attrs["filters"])
            except serializers.ValidationError as exc:
                raise serializers.ValidationError({"filters": exc.detail}) from None
            _check_values(profile, spec, attrs["filters"])

        mine = SavedView.objects.filter(org=profile.org, profile=profile, module=module)
        if instance is not None:
            mine = mine.exclude(pk=instance.pk)
        elif mine.count() >= MAX_VIEWS_PER_LIST:
            raise serializers.ValidationError(
                f"You can save at most {MAX_VIEWS_PER_LIST} views for one list."
            )
        name = attrs.get("name")
        if name is not None and mine.filter(name__iexact=name).exists():
            raise serializers.ValidationError(
                {"name": "You already have a view with this name for this list."}
            )
        return attrs

    def save(self, **kwargs):
        # Two saves racing past the check above meet the unique constraint;
        # answered as the same 400, not a 500.
        try:
            with transaction.atomic():
                return super().save(**kwargs)
        except IntegrityError:
            raise serializers.ValidationError(
                {"name": "You already have a view with this name for this list."}
            ) from None
