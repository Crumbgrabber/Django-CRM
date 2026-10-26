from drf_spectacular.openapi import AutoSchema as SpectacularAutoSchema
from rest_framework import serializers


def preprocessing_filter_spec(endpoints):
    filtered = []
    for path, path_regex, method, callback in endpoints:
        # Remove all but DRF API endpoints
        if path.startswith("/api/"):
            filtered.append((path, path_regex, method, callback))
    return filtered


# Keys a serializer's to_representation leaves out for some callers, so they
# stay optional in the schema.
CONDITIONAL_RESPONSE_FIELDS = {
    "APISettingsList": {"apikey"},  # admins only
    "InboundMailbox": {"has_webhook_secret", "topic_arn"},  # admins only
    "InboundMailboxListRow": {"has_webhook_secret", "topic_arn"},  # admins only
    # Not sent with include_counts=false.
    "CustomFieldDefinitionRow": {"records_missing_value"},
    "TimesheetEntry": {"live_duration_minutes"},  # running entries only
    # A read-only `source="<fk>.name"` field is skipped, not null, when the FK is empty.
    "InvoiceLineItem": {"product_name"},
    "EstimateLineItem": {"product_name"},
    "RecurringInvoiceLineItem": {"product_name"},
    "InvoiceList": {"account_name"},
    "EstimateList": {"account_name"},
    "RecurringInvoiceList": {"account_name"},
}


class AutoSchema(SpectacularAutoSchema):
    """drf-spectacular's AutoSchema, with model serializer responses fully required.

    drf-spectacular marks a response field required only when it is read-only
    or required on input, so a writable field with a model default comes out
    optional although a ModelSerializer always sends it. Plain serializers
    (`inline_serializer` envelopes included) keep their own `required` flags,
    which say what a view really leaves out. A ModelSerializer that does drop a
    key lists it in CONDITIONAL_RESPONSE_FIELDS; one that drops a key without
    being listed fails common/schema_contract.py.
    """

    def _map_basic_serializer(self, serializer, direction):
        schema = super()._map_basic_serializer(serializer, direction)
        if (
            direction == "response"
            and isinstance(serializer, serializers.ModelSerializer)
            and schema.get("properties")
        ):
            name = self._get_serializer_name(serializer, direction)
            optional = CONDITIONAL_RESPONSE_FIELDS.get(name, set())
            schema["required"] = [f for f in schema["properties"] if f not in optional]
        return schema
