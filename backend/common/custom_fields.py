"""Custom-field metadata + validation.

The CustomFieldDefinition model in common/models.py stores schema rows; this
module is the cross-cutting validator everyone uses to coerce/check values
before persisting them on an entity's `custom_fields` JSONField.

See docs/cases/tier1/custom-fields.md and docs/cases/COORDINATION_DECISIONS.md.
"""

from __future__ import annotations

import logging
import math
from datetime import date
from typing import Any

from django.db.models import JSONField, Q, Value
from django.db.models.fields.json import KeyTransform
from rest_framework import serializers as drf_serializers

from common.object_registry import BUILT_IN

logger = logging.getLogger(__name__)


def is_supported_target(target_model: str) -> bool:
    return any(e.custom_field_target == target_model for e in BUILT_IN)


def validate_definition_options(field_type: str, options: Any) -> None:
    """Raise serializers.ValidationError for malformed dropdown options."""
    if field_type != "dropdown":
        if options not in (None, [], {}):
            raise drf_serializers.ValidationError(
                {"options": "options is only valid for dropdown fields"}
            )
        return

    if not isinstance(options, list) or not options:
        raise drf_serializers.ValidationError(
            {
                "options": "Dropdown fields require a non-empty list of {value, label} pairs"
            }
        )

    seen: set[str] = set()
    for idx, entry in enumerate(options):
        if not isinstance(entry, dict):
            raise drf_serializers.ValidationError(
                {"options": f"Entry {idx} must be an object with value and label"}
            )
        value = entry.get("value")
        label = entry.get("label")
        if not isinstance(value, str) or not value:
            raise drf_serializers.ValidationError(
                {"options": f"Entry {idx} is missing a non-empty string value"}
            )
        if not isinstance(label, str) or not label:
            raise drf_serializers.ValidationError(
                {"options": f"Entry {idx} is missing a non-empty string label"}
            )
        if value in seen:
            raise drf_serializers.ValidationError(
                {"options": f"Duplicate dropdown value: {value!r}"}
            )
        seen.add(value)


# PostgreSQL jsonb refuses U+0000, so a value carrying one would be a 500.
_NUL_ERROR = "must not contain null characters"


def _coerce_value(field_type: str, raw: Any):
    """Coerce a raw input to the expected python/JSON type. Returns (value, error_or_None)."""
    if raw is None or raw == "":
        return None, None

    if field_type in ("text", "textarea"):
        text = str(raw)
        if "\x00" in text:
            return None, _NUL_ERROR
        return text, None

    if field_type == "number":
        try:
            if isinstance(raw, bool):
                raise ValueError
            number = float(raw) if isinstance(raw, (int, float)) else float(str(raw))
        except (OverflowError, TypeError, ValueError):
            return None, "must be a number"
        # NaN and infinity are not JSON, so neither a stored value nor a filter.
        if not math.isfinite(number):
            return None, "must be a number"
        return number, None

    if field_type == "checkbox":
        if isinstance(raw, bool):
            return raw, None
        if isinstance(raw, str):
            lowered = raw.strip().lower()
            if lowered in ("true", "1", "yes", "on"):
                return True, None
            if lowered in ("false", "0", "no", "off"):
                return False, None
        return None, "must be a boolean"

    if field_type == "date":
        if isinstance(raw, date):
            return raw.isoformat(), None
        if isinstance(raw, str):
            try:
                return date.fromisoformat(raw).isoformat(), None
            except ValueError:
                return None, "must be a YYYY-MM-DD date"
        return None, "must be a YYYY-MM-DD date"

    if field_type == "dropdown":
        text = str(raw)
        if "\x00" in text:
            return None, _NUL_ERROR
        return text, None

    return None, f"unsupported field_type {field_type!r}"


def validate_payload(
    target_model: str,
    value_dict: Any,
    org,
    *,
    existing: dict | None = None,
    definitions=None,
) -> tuple[dict, dict]:
    """Validate and coerce a custom_fields payload for an entity.

    Returns (cleaned_dict, errors_dict). Non-empty errors -> caller should 400.
    Unknown keys are dropped silently and logged. `existing` is the value
    currently stored on the entity, read from the database and never from the
    request. Required fields already set on the entity are preserved across
    PATCHes that omit them.

    Values tied to soft-deleted (is_active=False) definitions are carried
    forward on every save so admins can soft-delete a field without losing
    history. Writes against an inactive key are rejected as unknown, and the
    key arriving does not erase the stored value: the phone sends a record's
    whole stored map back on save.

    A value sent back exactly as stored is kept without being validated again,
    so a record still holding a dropdown option an admin has since removed can
    be saved. The stored copy is what is kept, so nothing the request carries
    is written unchecked.

    ``definitions`` is the org's definitions for ``target_model`` (active and
    inactive) when the caller has already loaded them; given, none are read.
    """
    from common.models import CustomFieldDefinition  # avoid import cycle

    if value_dict is None:
        value_dict = {}
    if not isinstance(value_dict, dict):
        return {}, {"custom_fields": "must be an object"}

    existing = existing or {}

    if definitions is None:
        definitions = CustomFieldDefinition.objects.filter(
            org=org, target_model=target_model
        )
    all_definitions = list(definitions)
    all_keys = {d.key for d in all_definitions}
    active_by_key = {d.key: d for d in all_definitions if d.is_active}

    cleaned: dict = {}
    errors: dict = {}

    # Carry forward existing recognized values the caller cannot change: the
    # ones it left out, and soft-deleted ones whatever it sent. Values whose
    # definition was hard-deleted are dropped. The schema is gone.
    for key, value in existing.items():
        if key in all_keys and (key not in value_dict or key not in active_by_key):
            cleaned[key] = value

    for key, raw in value_dict.items():
        defn = active_by_key.get(key)
        if defn is None:
            logger.info(
                "custom_fields: dropping unknown key %r on %s for org %s",
                key,
                target_model,
                getattr(org, "id", org),
            )
            continue
        if key in existing and raw == existing[key]:
            cleaned[key] = existing[key]
            continue
        coerced, error = _coerce_value(defn.field_type, raw)
        if error:
            errors[key] = error
            continue
        if coerced is None or coerced == "":
            cleaned.pop(key, None)
            continue
        if defn.field_type == "dropdown":
            allowed = {opt.get("value") for opt in (defn.options or [])}
            if coerced not in allowed:
                errors[key] = f"must be one of {sorted(allowed)}"
                continue
        cleaned[key] = coerced

    # Required fields: error if neither a new value nor an existing one is set.
    for defn in active_by_key.values():
        if not defn.is_required:
            continue
        present = cleaned.get(defn.key) not in (None, "")
        if not present:
            errors.setdefault(defn.key, "is required")

    return cleaned, errors


def custom_field_filter(target: str, org, params) -> Q:
    """The ``cf_<key>`` parameters of a list query as one ``Q`` on ``custom_fields``.

    Only the org's active fields for ``target`` count: any other ``cf_`` key is
    ignored, so a saved view on a field an admin later turned off still opens.
    A value is parsed by its field's type, so ``3`` matches a stored ``3.0`` and
    ``false`` a stored ``false``; one that does not parse is a 400 naming its
    parameter. A key is always one JSON key, never a lookup path.
    """
    wanted = {
        name[3:]: raw
        for name, raw in params.items()
        if name.startswith("cf_") and raw not in (None, "")
    }
    if not wanted:
        return Q()
    from common.models import CustomFieldDefinition  # avoid import cycle

    field_types = dict(
        CustomFieldDefinition.objects.filter(
            org=org, target_model=target, is_active=True, key__in=list(wanted)
        ).values_list("key", "field_type")
    )
    condition, errors = Q(), {}
    for key, raw in wanted.items():
        if key not in field_types:
            continue
        value, error = _coerce_value(field_types[key], raw)
        if error:
            errors[f"cf_{key}"] = [error]
            continue
        stored = KeyTransform(key, "custom_fields")
        # Typed as JSON here: built before the query resolves the column, the
        # lookup cannot learn the type from it and would compare a bare string.
        wanted_value = Value(value, output_field=JSONField())
        condition &= Q(stored.get_lookup("exact")(stored, wanted_value))
    if errors:
        raise drf_serializers.ValidationError(errors)
    return condition
