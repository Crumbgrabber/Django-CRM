"""Check API responses produced by the test suite against the OpenAPI schema.

The web app's API types are generated from this schema (`pnpm api:types` in
`frontend/`), so a response the schema leaves out, or describes wrongly, turns
into an untyped or mistyped value there. `conftest.py` runs `check_response` on
every response a test receives, and a response that has no schema, or does
not match it, fails the test. Fix the view's `@extend_schema(responses=...)`
to describe what it really returns, never the view.

Only what the schema declares is checked: undeclared extra keys pass. The web
app cannot read a key its type does not declare, so that side is caught by
`pnpm check` instead.
"""

import copy
import json
import re
from functools import cache

from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

_URN = "urn:bottlecrm:openapi"
_METHODS = ("get", "post", "put", "patch", "delete")


def _to_json_schema(node):
    """Rewrite OpenAPI 3.0 schema nodes for the JSON Schema validator, in place.

    `nullable: true` becomes a null type. `oneOf` becomes `anyOf`: formats are
    not asserted, so drf-spectacular's blank-allowed email or URL field,
    `oneOf: [{format: email}, {maxLength: 0}]`, would reject `''` for matching
    both branches. Only matching a branch matters for a response.
    """
    if isinstance(node, list):
        for item in node:
            _to_json_schema(item)
        return node
    if not isinstance(node, dict):
        return node
    for value in node.values():
        _to_json_schema(value)
    if "oneOf" in node:
        node["anyOf"] = node.pop("oneOf")
    if node.pop("nullable", False):
        if "type" in node and "enum" not in node:
            node["type"] = [node["type"], "null"]
        elif "enum" in node:
            node["enum"] = [*node["enum"], None]
        else:
            inner = {k: node.pop(k) for k in list(node)}
            node["anyOf"] = [inner, {"type": "null"}]
    return node


@cache
def _spec():
    from drf_spectacular.generators import SchemaGenerator
    from drf_spectacular.renderers import OpenApiJsonRenderer

    schema = SchemaGenerator().get_schema(request=None, public=True)
    document = json.loads(OpenApiJsonRenderer().render(schema, renderer_context={}))
    converted = _to_json_schema(copy.deepcopy(document))
    registry = Registry().with_resource(
        _URN, Resource.from_contents(converted, default_specification=DRAFT202012)
    )
    routes = []
    for path, item in document["paths"].items():
        pattern = re.compile(
            "^" + re.sub(r"\\\{[^}]+\\\}", "[^/]+", re.escape(path)) + "$"
        )
        routes.append((path.count("{"), path, pattern, item))
    # Prefer the most literal template: /api/leads/kanban/ over /api/leads/{id}/.
    routes.sort(key=lambda r: r[0])
    return routes, registry


@cache
def _validator(pointer):
    _, registry = _spec()
    return Draft202012Validator({"$ref": f"{_URN}#{pointer}"}, registry=registry)


def _pointer(*parts):
    return "/" + "/".join(str(p).replace("~", "~0").replace("/", "~1") for p in parts)


def check_response(response):
    """Problems with one test response, as a list of strings (empty when it conforms)."""
    request = response.request
    method = request.get("REQUEST_METHOD", "GET").lower()
    path = request.get("PATH_INFO", "")
    status = str(response.status_code)
    if (
        method not in _METHODS
        or not path.startswith("/api/")
        or not status.startswith("2")
    ):
        return []
    if status == "204" or "json" not in response.get("Content-Type", ""):
        return []
    routes, _ = _spec()
    match = next((r for r in routes if r[2].match(path) and method in r[3]), None)
    if match is None:
        return []
    template, operation = match[1], match[3][method]
    key = f"{method.upper()} {template}"
    content = operation.get("responses", {}).get(status, {}).get("content", {})
    media = next((m for m in content if "json" in m), None)
    if media is None or "schema" not in content[media]:
        return [f"SCHEMA-GAP {key}: no {status} response schema"]
    pointer = _pointer(
        "paths", template, method, "responses", status, "content", media, "schema"
    )
    body = json.loads(response.content or b"null")
    errors = sorted(_validator(pointer).iter_errors(body), key=lambda e: list(e.path))
    if not errors:
        return []
    first = errors[0]
    where = "/".join(str(p) for p in first.path) or "(root)"
    return [f"SCHEMA-GAP {key}: {status} at {where}: {first.message[:200]}"]
