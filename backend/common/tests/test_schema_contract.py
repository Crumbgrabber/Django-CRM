import json

from django.http import HttpResponse, JsonResponse

from common import schema_contract
from common.custom_openapi import CONDITIONAL_RESPONSE_FIELDS

ID = "0b9a9f0e-3c51-4bd5-9a43-7f3f8f1d2a11"
MERGE_TARGETS = f"/api/cases/{ID}/merge-targets/"


def _response(body, path=MERGE_TARGETS, method="GET", status=200):
    response = JsonResponse(body, status=status, safe=False)
    response.request = {"REQUEST_METHOD": method, "PATH_INFO": path}
    return response


def _components():
    routes, registry = schema_contract._spec()
    return registry.contents(schema_contract._URN)["components"]["schemas"]


class TestCheckResponse:
    def test_a_conforming_response_has_no_problems(self):
        assert schema_contract.check_response(_response({"results": []})) == []

    def test_a_missing_required_key_is_reported_with_the_operation(self):
        problems = schema_contract.check_response(_response({}))
        assert problems == [
            "SCHEMA-GAP GET /api/cases/{id}/merge-targets/: 200 at (root): "
            "'results' is a required property"
        ]

    def test_a_wrong_type_is_reported(self):
        problems = schema_contract.check_response(_response({"results": "nope"}))
        assert len(problems) == 1 and "at results" in problems[0]

    def test_an_operation_with_no_response_schema_is_reported(self):
        routes, _ = schema_contract._spec()
        template, method = next(
            (template, method)
            for _, template, _, item in routes
            for method, op in item.items()
            if method == "delete" and "200" not in op.get("responses", {})
        )
        path = template.replace("{id}", ID)
        problems = schema_contract.check_response(
            _response({}, path=path, method=method.upper())
        )
        assert problems == [
            f"SCHEMA-GAP {method.upper()} {template}: no 200 response schema"
        ]

    def test_errors_non_json_and_non_api_responses_are_not_checked(self):
        assert schema_contract.check_response(_response({}, status=404)) == []
        assert schema_contract.check_response(_response({}, path="/admin/")) == []
        csv = HttpResponse("a,b", content_type="text/csv")
        csv.request = {"REQUEST_METHOD": "GET", "PATH_INFO": MERGE_TARGETS}
        assert schema_contract.check_response(csv) == []

    def test_a_blank_string_matches_a_blank_allowed_email_field(self):
        node = {"oneOf": [{"type": "string", "format": "email"}, {"maxLength": 0}]}
        converted = schema_contract._to_json_schema(node)
        assert "oneOf" not in converted and len(converted["anyOf"]) == 2

    def test_nullable_is_read_as_json_schema(self):
        converted = schema_contract._to_json_schema(
            {"type": "string", "nullable": True}
        )
        assert converted == {"type": ["string", "null"]}
        wrapped = schema_contract._to_json_schema(
            {"allOf": [{"$ref": "#/x"}], "nullable": True}
        )
        assert wrapped == {"anyOf": [{"allOf": [{"$ref": "#/x"}]}, {"type": "null"}]}
        assert json.dumps(
            schema_contract._to_json_schema({"enum": ["a"], "nullable": True})
        ) == json.dumps({"enum": ["a", None]})


class TestRequiredResponseFields:
    def test_a_writable_field_with_a_default_is_required_in_responses(self):
        components = _components()
        assert "order" in components["BoardColumn"]["required"]
        assert "order" not in components["BoardColumnRequest"].get("required", [])

    def test_a_field_dropped_for_some_callers_stays_optional(self):
        components = _components()
        for name, fields in CONDITIONAL_RESPONSE_FIELDS.items():
            assert components[name]["properties"].keys() >= fields
            assert not fields & set(components[name]["required"])
