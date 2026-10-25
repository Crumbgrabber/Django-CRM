"""The projects API. The rules each view applies are in `projects.access`; a
project the caller may not open answers 404, like one that does not exist."""

from decimal import ROUND_HALF_UP, Decimal

from django.contrib.contenttypes.models import ContentType
from django.db import transaction
from django.utils import timezone
from drf_spectacular.utils import extend_schema, inline_serializer
from rest_framework import serializers, status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from cases.serializer import TimeEntryCreateSerializer, TimeEntrySerializer
from cases.time_views import _visible_entry_qs, create_entry, start_timer
from common.custom_fields import validate_payload as validate_custom_fields_payload
from common.models import Comment, Tags
from common.money import org_currency
from common.permissions import HasOrgContext, is_org_admin
from common.utils import create_attachment, validate_attachment
from common.validators import (
    payload_id_list,
    uuid_param,
    validate_date,
)
from invoices.api_views import _first_visible_contact
from invoices.models import Invoice, InvoiceLineItem
from opportunity.access import get_visible_deal
from projects import access
from projects.burn import burn_for, check_budget_alerts, unbilled_summary
from projects.serializer import (
    ProjectBodySerializer,
    ProjectDetailSerializer,
    ProjectListSerializer,
    ProjectWriteSerializer,
    _decoded,
    active_members,
    parse_rates,
    replace_rates,
)

NOT_FOUND = {"error": True, "errors": "Project not found."}
DEFAULT_LIMIT = 50
MAX_LIMIT = 200
_ATTACHMENT = "project_attachment"

_SAVED = inline_serializer(
    "ProjectSaved",
    {
        "error": serializers.BooleanField(),
        "id": serializers.UUIDField(),
        "project": ProjectDetailSerializer(),
    },
)


def _not_found():
    return Response(NOT_FOUND, status=status.HTTP_404_NOT_FOUND)


def _detail(request, project):
    return ProjectDetailSerializer(project, context={"profile": request.profile}).data


def _int_param(params, name, default):
    raw = params.get(name)
    if raw in (None, ""):
        return default
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise serializers.ValidationError({name: ["Send a whole number."]}) from None
    if value < 0:
        raise serializers.ValidationError({name: ["Send a number of 0 or more."]})
    return value


def _relations(request, data, project=None):
    """Everything a write takes beyond the scalar fields, checked before the
    first write. Only the keys present in ``data`` are returned, and ``rates``
    only for an admin (see ``ADMIN_ONLY_FIELDS``)."""
    org = request.profile.org
    out = {}
    if "assigned_to" in data:
        ids = payload_id_list(data.get("assigned_to"), "assigned_to")
        keep = project.assigned_to.values_list("id", flat=True) if project else ()
        out["assigned_to"] = active_members(org, ids, "assigned_to", keep)
    if "tags" in data:
        ids = payload_id_list(data.get("tags"), "tags")
        out["tags"] = list(Tags.objects.filter(id__in=ids, org=org, is_active=True))
    if "rates" in data and is_org_admin(request.profile):
        keep = project.rates.values_list("profile_id", flat=True) if project else ()
        out["rates"] = parse_rates(org, data.get("rates"), keep)
    if "custom_fields" in data or project is None:
        cleaned, errors = validate_custom_fields_payload(
            "Project",
            _decoded(data.get("custom_fields")) or {},
            org,
            existing=(project.custom_fields or {}) if project else None,
        )
        if errors:
            raise serializers.ValidationError({"custom_fields": errors})
        out["custom_fields"] = cleaned
    return out


def _save(request, serializer, relations, **save_kwargs):
    with transaction.atomic():
        if "custom_fields" in relations:
            save_kwargs["custom_fields"] = relations["custom_fields"]
        project = serializer.save(**save_kwargs)
        if "assigned_to" in relations:
            project.assigned_to.set(relations["assigned_to"])
        if "tags" in relations:
            project.tags.set(relations["tags"])
        if "rates" in relations:
            replace_rates(project, relations["rates"])
    check_budget_alerts(project)
    return project


def _errors(exc):
    return Response(
        {"error": True, "errors": exc.detail}, status=status.HTTP_400_BAD_REQUEST
    )


class ProjectListView(APIView):
    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_list",
        responses=inline_serializer(
            "ProjectListResponse",
            {
                "projects": ProjectListSerializer(many=True),
                "count": serializers.IntegerField(),
            },
        ),
    )
    def get(self, request):
        params = request.query_params
        queryset = access.visible_projects_qs(request.profile)
        if params.get("status"):
            queryset = queryset.filter(status=params["status"])
        account = uuid_param(params, "account")
        if account:
            queryset = queryset.filter(account_id=account)
        assignee = uuid_param(params, "assigned_to")
        if assignee:
            queryset = queryset.filter(assigned_to__id=assignee).distinct()
        if params.get("search"):
            queryset = queryset.filter(name__icontains=params["search"].strip())
        limit = min(_int_param(params, "limit", DEFAULT_LIMIT), MAX_LIMIT)
        offset = _int_param(params, "offset", 0)
        count = queryset.count()
        page = list(
            queryset.order_by("-created_at", "-id")
            .select_related("account", "deal")
            .prefetch_related("assigned_to__user", "tags")[offset : offset + limit]
        )
        rows = ProjectListSerializer(
            page,
            many=True,
            context={
                "profile": request.profile,
                "burn": burn_for(page, request.profile),
            },
        ).data
        return Response({"projects": rows, "count": count})

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_create",
        request=ProjectBodySerializer,
        responses={201: _SAVED},
    )
    def post(self, request):
        serializer = ProjectWriteSerializer(data=request.data, profile=request.profile)
        try:
            serializer.is_valid(raise_exception=True)
            relations = _relations(request, request.data)
        except serializers.ValidationError as exc:
            return _errors(exc)
        project = _save(
            request,
            serializer,
            relations,
            org=request.profile.org,
            created_by=request.profile.user,
        )
        return Response(
            {
                "error": False,
                "id": str(project.id),
                "project": _detail(request, project),
            },
            status=status.HTTP_201_CREATED,
        )


class ProjectDetailView(APIView):
    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_retrieve",
        responses=ProjectDetailSerializer,
    )
    def get(self, request, pk):
        project = access.get_visible_project(request.profile, pk)
        if project is None:
            return _not_found()
        return Response(_detail(request, project))

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_comment",
        request=inline_serializer(
            "ProjectComment",
            {
                "comment": serializers.CharField(required=False),
                "project_attachment": serializers.FileField(required=False),
            },
        ),
        responses=ProjectDetailSerializer,
    )
    def post(self, request, pk):
        """Add a comment, an attachment, or both, as on a deal."""
        project = access.get_visible_project(request.profile, pk)
        if project is None:
            return _not_found()
        upload = request.FILES.get(_ATTACHMENT)
        validate_attachment(upload)
        comment = (request.data.get("comment") or "").strip()
        if comment:
            Comment.objects.create(
                content_type=ContentType.objects.get_for_model(project),
                object_id=project.id,
                comment=comment,
                commented_by=request.profile,
                org=request.profile.org,
            )
        if upload:
            create_attachment(upload, project, request.profile)
        return Response(_detail(request, project))

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_partial_update",
        request=ProjectBodySerializer,
        responses=_SAVED,
    )
    def patch(self, request, pk):
        project = access.get_visible_project(request.profile, pk)
        if project is None:
            return _not_found()
        serializer = ProjectWriteSerializer(
            project, data=request.data, partial=True, profile=request.profile
        )
        try:
            serializer.is_valid(raise_exception=True)
            relations = _relations(request, request.data, project)
        except serializers.ValidationError as exc:
            return _errors(exc)
        project = _save(request, serializer, relations)
        return Response(
            {
                "error": False,
                "id": str(project.id),
                "project": _detail(request, project),
            }
        )

    @extend_schema(
        tags=["Projects"], operation_id="projects_destroy", responses={204: None}
    )
    def delete(self, request, pk):
        project = access.get_visible_project(request.profile, pk)
        if project is None:
            return _not_found()
        if not access.may_delete_project(request.profile, project):
            return Response(
                {
                    "error": True,
                    "errors": "You do not have Permission to perform this action",
                },
                status=status.HTTP_403_FORBIDDEN,
            )
        project.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class ProjectFromDealView(APIView):
    """A draft for the new-project form, filled from a deal. Saves nothing."""

    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_from_deal",
        responses=inline_serializer(
            "ProjectDraft",
            {
                "name": serializers.CharField(),
                "account": serializers.DictField(allow_null=True),
                "deal": serializers.DictField(),
                "currency": serializers.CharField(),
                "assigned_to": serializers.ListField(child=serializers.UUIDField()),
                "billing_type": serializers.CharField(),
                "budget_amount": serializers.DecimalField(
                    max_digits=12, decimal_places=2, allow_null=True
                ),
            },
        ),
    )
    def get(self, request, deal_id):
        deal = get_visible_deal(request.profile, deal_id)
        if deal is None:
            return Response(
                {"error": True, "errors": "Opportunity not found."},
                status=status.HTTP_404_NOT_FOUND,
            )
        account = deal.account
        return Response(
            {
                "name": deal.name,
                "account": (
                    {"id": str(account.id), "name": account.name} if account else None
                ),
                "deal": {"id": str(deal.id), "name": deal.name},
                "currency": deal.currency or org_currency(request.profile.org),
                "assigned_to": [
                    str(pk)
                    for pk in deal.assigned_to.filter(is_active=True).values_list(
                        "id", flat=True
                    )
                ],
                "billing_type": "fixed_fee" if deal.amount else "time_and_materials",
                "budget_amount": str(deal.amount) if deal.amount else None,
            }
        )


class ProjectTimeEntriesView(APIView):
    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_time_entries_list",
        responses=TimeEntrySerializer(many=True),
    )
    def get(self, request, pk):
        project = access.get_visible_project(request.profile, pk)
        if project is None:
            return _not_found()
        entries = (
            _visible_entry_qs(request.profile)
            .filter(project=project)
            .order_by("-started_at")
        )
        return Response(TimeEntrySerializer(entries, many=True).data)

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_time_entries_create",
        request=TimeEntryCreateSerializer,
        responses={201: TimeEntrySerializer},
    )
    def post(self, request, pk):
        # Logging needs edit access, which on a project is the read rule.
        project = access.get_visible_project(request.profile, pk)
        if project is None:
            return _not_found()
        return create_entry(request, project=project)


class ProjectTimerStartView(APIView):
    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_time_entries_start",
        request=None,
        responses={201: TimeEntrySerializer},
    )
    @transaction.atomic
    def post(self, request, pk):
        project = access.get_visible_project(request.profile, pk)
        if project is None:
            return _not_found()
        return start_timer(request, project=project)


def _billing_refusal(request):
    if access.may_bill_project(request.profile):
        return None
    return Response(
        {"error": True, "message": "Only admins can bill a project."},
        status=status.HTTP_403_FORBIDDEN,
    )


class ProjectUnbilledView(APIView):
    """What billing the project up to a date would take, for the bill dialog."""

    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_unbilled",
        responses=inline_serializer(
            "ProjectUnbilled",
            {
                "entry_count": serializers.IntegerField(),
                "hours": serializers.DecimalField(max_digits=10, decimal_places=2),
                "value": serializers.DecimalField(max_digits=14, decimal_places=2),
                "currency": serializers.CharField(),
                "unrated_count": serializers.IntegerField(),
            },
        ),
    )
    def get(self, request, pk):
        refusal = _billing_refusal(request)
        if refusal:
            return refusal
        project = access.get_visible_project(request.profile, pk)
        if project is None:
            return _not_found()
        raw = request.query_params.get("up_to")
        up_to = validate_date(raw, "up_to") if raw else timezone.localdate()
        return Response(unbilled_summary(project, up_to))


class InvoiceAmountSerializer(serializers.Serializer):
    amount = serializers.DecimalField(
        max_digits=12, decimal_places=2, required=False, allow_null=True
    )
    percent = serializers.DecimalField(
        max_digits=5, decimal_places=2, required=False, allow_null=True
    )
    description = serializers.CharField(
        required=False, allow_blank=True, allow_null=True, max_length=500
    )

    def validate(self, attrs):
        amount, percent = attrs.get("amount"), attrs.get("percent")
        if (amount is None) == (percent is None):
            raise serializers.ValidationError(
                {"amount": ["Send either an amount or a percent."]}
            )
        if amount is not None and amount <= 0:
            raise serializers.ValidationError(
                {"amount": ["The amount must be more than 0."]}
            )
        if percent is not None and not (0 < percent <= 100):
            raise serializers.ValidationError(
                {"percent": ["The percent must be more than 0 and at most 100."]}
            )
        return attrs


class ProjectInvoiceAmountView(APIView):
    """A one-line Draft invoice for an amount or a share of the budget."""

    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        tags=["Projects"],
        operation_id="projects_invoice_amount",
        request=InvoiceAmountSerializer,
        responses={
            201: inline_serializer(
                "ProjectInvoiceAmount",
                {
                    "invoice_id": serializers.UUIDField(),
                    "invoice_number": serializers.CharField(),
                },
            )
        },
    )
    def post(self, request, pk):
        refusal = _billing_refusal(request)
        if refusal:
            return refusal
        project = access.get_visible_project(request.profile, pk)
        if project is None:
            return _not_found()
        serializer = InvoiceAmountSerializer(data=request.data)
        if not serializer.is_valid():
            return Response(
                {"error": True, "errors": serializer.errors},
                status=status.HTTP_400_BAD_REQUEST,
            )
        data = serializer.validated_data
        if data.get("percent") is not None:
            if not project.budget_amount:
                return Response(
                    {
                        "error": True,
                        "errors": {
                            "percent": ["Set the project's budget amount first."]
                        },
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )
            amount = (project.budget_amount * data["percent"] / 100).quantize(
                Decimal("0.01"), rounding=ROUND_HALF_UP
            )
        else:
            amount = data["amount"]
        label = (data.get("description") or "").strip() or f"{project.name}, fixed fee"
        org = request.profile.org
        with transaction.atomic():
            invoice = Invoice.objects.create(
                invoice_title=label[:100],
                account=project.account,
                contact=_first_visible_contact(
                    project.account.contacts, request.profile
                ),
                currency=project.currency,
                status="Draft",
                project=project,
                org=org,
            )
            InvoiceLineItem.objects.create(
                invoice=invoice,
                org=org,
                name=label[:255],
                description=label[:500],
                quantity=Decimal("1"),
                unit_price=amount,
                order=0,
            )
            invoice.recalculate_totals()
            invoice.save()
        return Response(
            {"invoice_id": str(invoice.id), "invoice_number": invoice.invoice_number},
            status=status.HTTP_201_CREATED,
        )
