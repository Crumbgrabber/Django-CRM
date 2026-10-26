"""REST endpoints for the cases analytics dashboard.

The six metric endpoints (FRT, NRT, MTTR, Backlog, Agents, SLA) plus a
drilldown JSON endpoint and a streaming CSV export. All accept the same
filter set: `from`, `to`, `team`, `agent`, `priority`. Default window is
the last 30 days.

See `docs/cases/tier2/reporting.md` for the response shapes.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional
from uuid import UUID

from django.utils import timezone
from drf_spectacular.utils import OpenApiParameter, extend_schema, inline_serializer
from rest_framework import serializers
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from cases import analytics
from cases.access import is_org_admin, visible_cases_qs
from cases.analytics import DEFAULT_SERVICE_DAYS
from cases.models import Case
from cases.serializer import CaseSerializer, parent_access_context
from common.csv_export import csv_response, local_iso
from common.permissions import HasOrgContext
from common.renderers import CSV_RENDERERS
from common.validators import uuid_param

# ---------------------------------------------------------------------------
# Shared filter parsing


def _parse_dt(
    value: str, field: str, *, end_of_day: bool = False
) -> Optional[datetime]:
    """Accepts YYYY-MM-DD (the org's midnight) or full ISO-8601.

    A date picker sends the day the user pointed at, not an instant. Anchoring
    it to UTC midnight would ask an Indian org about a window that starts at
    05:30 on the chosen day and ends at 05:30 on the day after the one they
    picked, so the answer would silently cover the wrong 24 hours.

    A value that will not parse is refused rather than dropped. Returning
    ``None`` for it fell through to the default last-30-days window, so
    ``?from=banana`` was answered 200 with figures for a period nobody asked
    about, and a client with a broken date format had no way to find out. Every
    other date-valued parameter in this API answers 400 (see
    ``common.validators.date_param``); this one now agrees with them.
    """
    if not value:
        return None
    try:
        # Date-only: anchor to the org's midnight; end_of_day means the
        # exclusive upper bound, so the whole chosen day is inside the window.
        if len(value) == 10 and value.count("-") == 2:
            d = datetime.fromisoformat(value)
            return timezone.make_aware(d + timedelta(days=1) if end_of_day else d)
        return datetime.fromisoformat(value)
    except ValueError:
        raise ValidationError(
            {
                field: [
                    f"'{value}' is not a valid date. "
                    "Use YYYY-MM-DD or an ISO-8601 timestamp."
                ]
            }
        ) from None


def _parse_days(value) -> int:
    """The service window's length, in whole days.

    Absent means the default. A value that is not a whole number is refused for
    the same reason a malformed ``from`` is: silently answering about 14 days
    when asked about ``banana`` looks like an answer. Out-of-range is a
    different case and stays a clamp, which `compute_service_overview`
    documents: 999 days is a legible request for "as much as you have".
    """
    if value in (None, ""):
        return DEFAULT_SERVICE_DAYS
    try:
        return int(value)
    except (TypeError, ValueError):
        raise ValidationError(
            {"days": [f"'{value}' is not a whole number of days."]}
        ) from None


def _filtered_qs(request) -> tuple[object, datetime, datetime]:
    """Build the org-scoped Case queryset + (from, to) window from query params.

    Visibility is `visible_cases_qs`, the ticket read rule: admins and
    superusers see every case; everyone else only those they created, are
    assigned to, or watch. This used to carry its own copy of that rule.
    """
    profile = request.profile
    params = request.query_params

    qs = (
        visible_cases_qs(profile)
        .filter(is_active=True, merged_into__isnull=True)
        .exclude(status="Duplicate")
    )

    if priority := params.get("priority"):
        qs = qs.filter(priority=priority)
    if team_id := uuid_param(params, "team"):
        qs = qs.filter(teams=team_id)
    if agent_id := uuid_param(params, "agent"):
        qs = qs.filter(assigned_to=agent_id)

    from_dt = _parse_dt(params.get("from", ""), "from")
    to_dt = _parse_dt(params.get("to", ""), "to", end_of_day=True)
    # Coerce defaults (last 30 days) consistently with the analytics module.
    coerced_from, coerced_to = analytics._coerce_window(from_dt, to_dt)
    return qs, coerced_from, coerced_to


# ---------------------------------------------------------------------------
# Metric endpoints


_FILTER_PARAMS = [
    OpenApiParameter(
        "from", str, description="Start of window (ISO-8601 or YYYY-MM-DD)"
    ),
    OpenApiParameter("to", str, description="End of window (ISO-8601 or YYYY-MM-DD)"),
    OpenApiParameter("team", str, description="Filter to one team's cases"),
    OpenApiParameter("agent", str, description="Filter to one assignee profile"),
    OpenApiParameter("priority", str, description="Filter by priority"),
]


# ---------------------------------------------------------------------------
# Response shapes, for the schema only (see `cases.analytics` for the figures)


class AnalyticsMedianBucketSerializer(serializers.Serializer):
    bucket = serializers.DateField()
    median = serializers.FloatField(allow_null=True)
    count = serializers.IntegerField()


class AnalyticsNrtPrioritySerializer(serializers.Serializer):
    priority = serializers.CharField()
    target_hours = serializers.IntegerField()
    median_hours = serializers.FloatField(allow_null=True)
    met = serializers.IntegerField()
    missed = serializers.IntegerField()


class AnalyticsMttrPrioritySerializer(serializers.Serializer):
    mean_hours = serializers.FloatField()
    median_hours = serializers.FloatField()
    p90_hours = serializers.FloatField()
    count = serializers.IntegerField()


class AnalyticsBacklogDaySerializer(serializers.Serializer):
    date = serializers.DateField()
    open_count = serializers.IntegerField()
    urgent_count = serializers.IntegerField()


class AnalyticsAgentSerializer(serializers.Serializer):
    profile_id = serializers.UUIDField()
    name = serializers.CharField()
    email = serializers.CharField()
    handled = serializers.IntegerField()
    avg_frt_hours = serializers.FloatField(allow_null=True)
    csat_avg = serializers.FloatField(allow_null=True)
    breach_rate = serializers.FloatField()


class AnalyticsSlaPrioritySerializer(serializers.Serializer):
    total = serializers.IntegerField()
    frt_breach_rate = serializers.FloatField()
    resolution_breach_rate = serializers.FloatField()
    nrt_breach_rate = serializers.FloatField()


class ServiceTotalsSerializer(serializers.Serializer):
    opened = serializers.IntegerField()
    closed = serializers.IntegerField()
    open_now = serializers.IntegerField()
    median_resolution_hours = serializers.IntegerField()
    window_days = serializers.IntegerField()
    business_hours_applied = serializers.BooleanField()
    calendar_name = serializers.CharField(allow_null=True)


class ServiceVolumeDaySerializer(serializers.Serializer):
    date = serializers.DateField()
    opened = serializers.IntegerField()
    closed = serializers.IntegerField()


class ServiceFirstResponseSerializer(serializers.Serializer):
    priority = serializers.CharField()
    target_minutes = serializers.IntegerField()
    median_minutes = serializers.IntegerField(allow_null=True)
    met = serializers.IntegerField()
    missed = serializers.IntegerField()


class ServiceCaseTypeSerializer(serializers.Serializer):
    case_type = serializers.CharField()
    count = serializers.IntegerField()


class ServiceAgentSerializer(serializers.Serializer):
    # Null on the "Unassigned" row.
    id = serializers.UUIDField(allow_null=True)
    name = serializers.CharField()
    open = serializers.IntegerField()
    closed_this_week = serializers.IntegerField()
    median_first_response_minutes = serializers.IntegerField(allow_null=True)
    breached = serializers.IntegerField()


def _case_ids():
    # A new field per use: one instance shared by two keys binds to one name.
    return serializers.ListField(child=serializers.UUIDField())


FRT_RESPONSE = inline_serializer(
    name="AnalyticsFrtResponse",
    fields={
        "median_hours": serializers.FloatField(allow_null=True),
        "p90_hours": serializers.FloatField(allow_null=True),
        "count": serializers.IntegerField(),
        "breach_count": serializers.IntegerField(),
        "series": AnalyticsMedianBucketSerializer(many=True),
        "case_ids": _case_ids(),
        "breach_case_ids": _case_ids(),
    },
)

NRT_RESPONSE = inline_serializer(
    name="AnalyticsNrtResponse",
    fields={
        "median_hours": serializers.FloatField(allow_null=True),
        "p90_hours": serializers.FloatField(allow_null=True),
        "count": serializers.IntegerField(),
        "breach_count": serializers.IntegerField(),
        "series": AnalyticsMedianBucketSerializer(many=True),
        "by_priority": AnalyticsNrtPrioritySerializer(many=True),
        "case_ids": _case_ids(),
        "breach_case_ids": _case_ids(),
    },
)

MTTR_RESPONSE = inline_serializer(
    name="AnalyticsMttrResponse",
    fields={
        "mean_hours": serializers.FloatField(allow_null=True),
        "median_hours": serializers.FloatField(allow_null=True),
        "p90_hours": serializers.FloatField(allow_null=True),
        "count": serializers.IntegerField(),
        # Keyed by priority; only priorities with a resolved case appear.
        "by_priority": serializers.DictField(child=AnalyticsMttrPrioritySerializer()),
        "case_ids": _case_ids(),
    },
)

BACKLOG_RESPONSE = inline_serializer(
    name="AnalyticsBacklogResponse",
    fields={"series": AnalyticsBacklogDaySerializer(many=True)},
)

AGENTS_RESPONSE = inline_serializer(
    name="AnalyticsAgentsResponse",
    fields={"results": AnalyticsAgentSerializer(many=True)},
)

SLA_RESPONSE = inline_serializer(
    name="AnalyticsSlaResponse",
    fields={
        "total": serializers.IntegerField(),
        "frt_breach_count": serializers.IntegerField(),
        "resolution_breach_count": serializers.IntegerField(),
        "nrt_breach_count": serializers.IntegerField(),
        "frt_breach_rate": serializers.FloatField(allow_null=True),
        "resolution_breach_rate": serializers.FloatField(allow_null=True),
        "nrt_breach_rate": serializers.FloatField(allow_null=True),
        # Keyed by priority; only priorities with a case in the window appear.
        "by_priority": serializers.DictField(child=AnalyticsSlaPrioritySerializer()),
        "frt_breach_case_ids": _case_ids(),
        "resolution_breach_case_ids": _case_ids(),
        "nrt_breach_case_ids": _case_ids(),
    },
)

SERVICE_RESPONSE = inline_serializer(
    name="AnalyticsServiceResponse",
    fields={
        "totals": ServiceTotalsSerializer(),
        "volume": ServiceVolumeDaySerializer(many=True),
        "first_response": ServiceFirstResponseSerializer(many=True),
        "by_type": ServiceCaseTypeSerializer(many=True),
        "by_agent": ServiceAgentSerializer(many=True),
    },
)

DRILLDOWN_RESPONSE = inline_serializer(
    name="AnalyticsDrilldownResponse",
    fields={
        "count": serializers.IntegerField(),
        "results": CaseSerializer(many=True),
    },
)


class _AnalyticsBaseView(APIView):
    permission_classes = (IsAuthenticated, HasOrgContext)


class AnalyticsFrtView(_AnalyticsBaseView):
    @extend_schema(
        tags=["cases-analytics"],
        parameters=_FILTER_PARAMS,
        responses={200: FRT_RESPONSE},
    )
    def get(self, request):
        qs, from_dt, to_dt = _filtered_qs(request)
        return Response(analytics.compute_frt(qs, from_dt, to_dt))


class AnalyticsNrtView(_AnalyticsBaseView):
    @extend_schema(
        tags=["cases-analytics"],
        parameters=_FILTER_PARAMS,
        responses={200: NRT_RESPONSE},
    )
    def get(self, request):
        qs, from_dt, to_dt = _filtered_qs(request)
        return Response(
            analytics.compute_nrt(qs, from_dt, to_dt, org_id=request.profile.org_id)
        )


class AnalyticsMttrView(_AnalyticsBaseView):
    @extend_schema(
        tags=["cases-analytics"],
        parameters=_FILTER_PARAMS,
        responses={200: MTTR_RESPONSE},
    )
    def get(self, request):
        qs, from_dt, to_dt = _filtered_qs(request)
        return Response(analytics.compute_mttr(qs, from_dt, to_dt))


class AnalyticsBacklogView(_AnalyticsBaseView):
    @extend_schema(
        tags=["cases-analytics"],
        parameters=_FILTER_PARAMS,
        responses={200: BACKLOG_RESPONSE},
    )
    def get(self, request):
        qs, from_dt, to_dt = _filtered_qs(request)
        return Response(analytics.compute_backlog(qs, from_dt, to_dt))


class AnalyticsAgentsView(_AnalyticsBaseView):
    @extend_schema(
        tags=["cases-analytics"],
        parameters=_FILTER_PARAMS,
        responses={200: AGENTS_RESPONSE},
    )
    def get(self, request):
        qs, from_dt, to_dt = _filtered_qs(request)
        return Response({"results": analytics.compute_agents(qs, from_dt, to_dt)})


class AnalyticsSlaView(_AnalyticsBaseView):
    @extend_schema(
        tags=["cases-analytics"],
        parameters=_FILTER_PARAMS,
        responses={200: SLA_RESPONSE},
    )
    def get(self, request):
        qs, from_dt, to_dt = _filtered_qs(request)
        return Response(analytics.compute_sla(qs, from_dt, to_dt))


class AnalyticsServiceView(_AnalyticsBaseView):
    """Admin-only single-call dashboard behind /v2/tickets/analytics.

    Returns org-wide service KPIs (totals, per-day volume, first-response
    attainment by priority, case-type mix, per-agent table). Unlike the
    per-metric endpoints above, which narrow a non-admin to their own cases
    and would therefore show a personal slice under org-wide headings. This
    view is an org-aggregate management surface, so it 403s non-admins outright
    (mirrors the invoices/reports policy for whole-org figures).
    """

    @extend_schema(
        tags=["cases-analytics"],
        parameters=[
            OpenApiParameter(
                "days",
                int,
                description="Window length in whole days (default 14, max 90)",
            )
        ],
        responses={200: SERVICE_RESPONSE},
    )
    def get(self, request):
        if not is_org_admin(request.profile):
            return Response(
                {"error": True, "errors": "Admin access required"}, status=403
            )
        days = _parse_days(request.query_params.get("days"))
        qs = (
            visible_cases_qs(request.profile)
            .filter(is_active=True, merged_into__isnull=True)
            .exclude(status="Duplicate")
        )
        data = analytics.compute_service_overview(qs, request.profile.org_id, days)
        return Response(data)


# ---------------------------------------------------------------------------
# Drilldown + CSV export


class AnalyticsDrilldownView(_AnalyticsBaseView):
    @extend_schema(
        tags=["cases-analytics"],
        parameters=_FILTER_PARAMS
        + [
            OpenApiParameter("metric", str, required=True),
            OpenApiParameter(
                "bucket", str, description="Bucket selector (metric-specific)"
            ),
        ],
        responses={200: DRILLDOWN_RESPONSE},
    )
    def get(self, request):
        metric = request.query_params.get("metric", "")
        bucket = request.query_params.get("bucket")
        qs, from_dt, to_dt = _filtered_qs(request)
        try:
            ids = list(
                analytics.case_ids_for_metric(metric, qs, from_dt, to_dt, bucket)
            )
        except ValueError as exc:
            return Response({"error": str(exc)}, status=400)
        cases = Case.objects.filter(org=request.profile.org, id__in=ids).order_by(
            "-created_at"
        )
        data = CaseSerializer(
            cases, many=True, context=parent_access_context(request.profile, cases)
        ).data
        return Response({"count": len(data), "results": data})


# CSV columns kept tight on purpose: analyst pivots externally.
_CSV_COLUMNS = (
    ("id", "ID"),
    ("name", "Name"),
    ("status", "Status"),
    ("priority", "Priority"),
    ("created_at", "Created"),
    ("first_response_at", "First response"),
    ("resolved_at", "Resolved"),
    ("sla_first_response_hours", "FRT SLA hrs"),
    ("sla_resolution_hours", "Resolution SLA hrs"),
)


class AnalyticsExportView(_AnalyticsBaseView):
    # This endpoint answers in CSV, so it has to say it accepts CSV: content
    # negotiation runs before the handler, and a client that asks for
    # `Accept: text/csv` would otherwise be answered 406.
    renderer_classes = CSV_RENDERERS

    @extend_schema(
        tags=["cases-analytics"],
        parameters=_FILTER_PARAMS
        + [
            OpenApiParameter("metric", str, required=True),
            OpenApiParameter("bucket", str),
            OpenApiParameter(
                "fmt",
                str,
                description="csv (only). Named `fmt` to avoid colliding with DRF's "
                "`?format=` content-negotiation kwarg, which would 404 the endpoint.",
            ),
        ],
    )
    def get(self, request):
        metric = request.query_params.get("metric", "")
        bucket = request.query_params.get("bucket")
        fmt = request.query_params.get("fmt", "csv")
        if fmt != "csv":
            return Response({"error": "only fmt=csv is supported"}, status=400)

        qs, from_dt, to_dt = _filtered_qs(request)
        try:
            ids_iter = analytics.case_ids_for_metric(metric, qs, from_dt, to_dt, bucket)
        except ValueError as exc:
            return Response({"error": str(exc)}, status=400)

        ids = [UUID(str(cid)) for cid in ids_iter]
        cases_qs = Case.objects.filter(org=request.profile.org, id__in=ids).order_by(
            "-created_at"
        )

        def rows():
            yield [label for _key, label in _CSV_COLUMNS]
            for c in cases_qs.iterator(chunk_size=200):
                yield [
                    str(c.id),
                    c.name,
                    c.status,
                    c.priority,
                    local_iso(c.created_at),
                    local_iso(c.first_response_at),
                    local_iso(c.resolved_at),
                    c.sla_first_response_hours,
                    c.sla_resolution_hours,
                ]

        return csv_response(
            rows(), f"cases-{metric}-{bucket or 'all'}.csv", request.profile.org
        )
