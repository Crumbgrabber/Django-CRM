import json
import uuid
from decimal import Decimal

from django.contrib.contenttypes.models import ContentType
from django.utils import timezone
from drf_spectacular.utils import extend_schema_field
from rest_framework import serializers

from accounts.access import has_account_access
from accounts.models import Account
from common.models import Attachments, Comment, Profile
from common.modules import module_is_available, module_off_message, org_of
from common.money import org_currency
from common.permissions import is_org_admin
from common.serializer import (
    AttachmentsSerializer,
    CommentSerializer,
    ProfileSerializer,
    TagsSerializer,
)
from common.validators import validate_uuid
from invoices.permissions import visible_estimates_qs, visible_invoices_qs
from opportunity.access import has_deal_access
from opportunity.models import Opportunity
from projects import access
from projects.burn import burn_for
from projects.models import Project, ProjectRate
from projects.retainers import RETAINER, retainer_usage


def _ref(record):
    return {"id": str(record.pk), "name": record.name} if record else None


def _money():
    return serializers.DecimalField(max_digits=None, decimal_places=2)


class ProjectRefSerializer(serializers.Serializer):
    """`_ref`: a project's account or deal, for the schema."""

    id = serializers.UUIDField()
    name = serializers.CharField()


class ProjectBurnSerializer(serializers.Serializer):
    """`projects.burn.burn_for`: one project's burn, for the schema."""

    logged_hours = _money()
    billable_hours = _money()
    billable_value = _money()
    unbilled_value = _money()
    invoiced_amount = serializers.DecimalField(
        max_digits=None, decimal_places=2, allow_null=True
    )
    hours_percent = serializers.IntegerField(allow_null=True)
    amount_percent = serializers.IntegerField(allow_null=True)


class ProjectRetainerUsageSerializer(serializers.Serializer):
    """`projects.retainers.retainer_usage`, for the schema."""

    month = serializers.CharField(help_text="YYYY-MM")
    used_hours = _money()
    available_hours = serializers.DecimalField(
        max_digits=None, decimal_places=2, allow_null=True
    )
    overage_hours = _money()
    billable_now = serializers.BooleanField()


class ProjectRateRowSerializer(serializers.Serializer):
    """One `ProjectDetailSerializer.rates` entry, for the schema."""

    profile = ProfileSerializer()
    hourly_rate = _money()


class ProjectInvoiceRowSerializer(serializers.Serializer):
    """One `ProjectDetailSerializer.invoices` entry, for the schema."""

    id = serializers.UUIDField()
    invoice_number = serializers.CharField()
    status = serializers.CharField()
    total_amount = _money()
    currency = serializers.CharField()
    issue_date = serializers.DateField(allow_null=True)


class ProjectEstimateSerializer(serializers.Serializer):
    """`ProjectDetailSerializer.estimate`, for the schema."""

    id = serializers.UUIDField()
    estimate_number = serializers.CharField()


RETAINER_FIELDS = (
    "retainer_fee",
    "retainer_hours",
    "retainer_rollover",
    "retainer_overage_rate",
    "retainer_carried_hours",
)


class ProjectListSerializer(serializers.ModelSerializer):
    """One list row. Needs the request's profile as ``context["profile"]``;
    pass ``context["burn"] = burn_for(rows, profile)`` for a page of rows, so
    the burn costs two queries for the page, not two per row."""

    account = serializers.SerializerMethodField()
    deal = serializers.SerializerMethodField()
    assigned_to = ProfileSerializer(many=True, read_only=True)
    tags = TagsSerializer(many=True, read_only=True)
    burn = serializers.SerializerMethodField()

    class Meta:
        model = Project
        fields = (
            "id",
            "name",
            "account",
            "deal",
            "status",
            "billing_type",
            "currency",
            "budget_hours",
            "budget_amount",
            "hourly_rate",
            *RETAINER_FIELDS,
            "retainer_next_month",
            "retainer_last_month",
            "start_date",
            "due_date",
            "assigned_to",
            "tags",
            "burn",
            "created_at",
            "updated_at",
        )
        read_only_fields = fields

    @extend_schema_field(ProjectRefSerializer)
    def get_account(self, obj):
        return _ref(obj.account)

    @extend_schema_field(ProjectRefSerializer(allow_null=True))
    def get_deal(self, obj):
        if obj.deal_id is None or not module_is_available(org_of(obj), "deals"):
            return None
        return _ref(obj.deal)

    @extend_schema_field(ProjectBurnSerializer)
    def get_burn(self, obj):
        burn = self.context.get("burn")
        if burn is None or obj.pk not in burn:
            burn = burn_for([obj], self.context["profile"])
        return burn[obj.pk]


class ProjectDetailSerializer(ProjectListSerializer):
    """The list row plus what the project page shows. Needs the request's
    profile as ``context["profile"]``."""

    rates = serializers.SerializerMethodField()
    comments = serializers.SerializerMethodField()
    attachments = serializers.SerializerMethodField()
    invoices = serializers.SerializerMethodField()
    estimate = serializers.SerializerMethodField()
    can_edit = serializers.SerializerMethodField()
    can_delete = serializers.SerializerMethodField()
    can_bill = serializers.SerializerMethodField()
    retainer_usage = serializers.SerializerMethodField()

    class Meta(ProjectListSerializer.Meta):
        fields = ProjectListSerializer.Meta.fields + (
            "description",
            "custom_fields",
            "retainer_usage",
            "rates",
            "comments",
            "attachments",
            "invoices",
            "estimate",
            "can_edit",
            "can_delete",
            "can_bill",
        )
        read_only_fields = fields

    def _attached(self, model, obj):
        return model.objects.filter(
            content_type=ContentType.objects.get_for_model(Project),
            object_id=obj.pk,
            org_id=obj.org_id,
        ).order_by("-id")

    @extend_schema_field(ProjectRateRowSerializer(many=True))
    def get_rates(self, obj):
        rows = obj.rates.select_related("profile__user").order_by("created_at")
        return [
            {
                "profile": ProfileSerializer(r.profile).data,
                "hourly_rate": str(r.hourly_rate),
            }
            for r in rows
        ]

    @extend_schema_field(CommentSerializer(many=True))
    def get_comments(self, obj):
        return CommentSerializer(self._attached(Comment, obj), many=True).data

    @extend_schema_field(AttachmentsSerializer(many=True))
    def get_attachments(self, obj):
        return AttachmentsSerializer(self._attached(Attachments, obj), many=True).data

    @extend_schema_field(ProjectInvoiceRowSerializer(many=True))
    def get_invoices(self, obj):
        profile = self.context["profile"]
        if not module_is_available(profile.org, "invoices"):
            return []
        rows = (
            visible_invoices_qs(profile)
            .filter(project=obj)
            .order_by("-issue_date", "-created_at")
        )
        return [
            {
                "id": str(i.pk),
                "invoice_number": i.invoice_number,
                "status": i.status,
                "total_amount": str(i.total_amount),
                "currency": i.currency,
                "issue_date": i.issue_date.isoformat() if i.issue_date else None,
            }
            for i in rows
        ]

    @extend_schema_field(ProjectEstimateSerializer(allow_null=True))
    def get_estimate(self, obj):
        """The estimate whose acceptance started the project, if the caller
        may open it."""
        profile = self.context["profile"]
        if not module_is_available(profile.org, "invoices"):
            return None
        estimate = (
            visible_estimates_qs(profile)
            .filter(project=obj)
            .order_by("created_at")
            .values("id", "estimate_number")
            .first()
        )
        if estimate is None:
            return None
        return {
            "id": str(estimate["id"]),
            "estimate_number": estimate["estimate_number"],
        }

    def get_can_edit(self, obj) -> bool:
        return access.has_project_access(self.context["profile"], obj)

    def get_can_delete(self, obj) -> bool:
        return access.may_delete_project(self.context["profile"], obj)

    def get_can_bill(self, obj) -> bool:
        return access.may_bill_project(self.context["profile"])

    @extend_schema_field(ProjectRetainerUsageSerializer(allow_null=True))
    def get_retainer_usage(self, obj):
        return retainer_usage(obj, timezone.localdate())


# A member's write leaves these as they are (a new project keeps the defaults):
# what the org charges is an admin's to set, as is moving a project to another
# client once it exists.
ADMIN_ONLY_FIELDS = (
    "billing_type",
    "currency",
    "budget_hours",
    "budget_amount",
    "hourly_rate",
    *RETAINER_FIELDS,
)


class ProjectWriteSerializer(serializers.ModelSerializer):
    """The scalar fields of a create or PATCH. ``assigned_to``, ``tags``,
    ``rates`` and ``custom_fields`` are parsed by ``projects.views._relations``."""

    budget_hours = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0"),
        required=False,
        allow_null=True,
    )
    budget_amount = serializers.DecimalField(
        max_digits=12,
        decimal_places=2,
        min_value=Decimal("0"),
        required=False,
        allow_null=True,
    )
    hourly_rate = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0"),
        required=False,
        allow_null=True,
    )
    currency = serializers.ChoiceField(
        choices=Project._meta.get_field("currency").choices,
        required=False,
        allow_blank=True,
    )
    retainer_fee = serializers.DecimalField(
        max_digits=12,
        decimal_places=2,
        min_value=Decimal("0.01"),
        required=False,
        allow_null=True,
    )
    # The hours in the longest month, so carried hours stay within the column.
    retainer_hours = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0"),
        max_value=Decimal("744"),
        required=False,
        allow_null=True,
        error_messages={"max_value": "At most 744 hours, the hours in a month."},
    )
    retainer_overage_rate = serializers.DecimalField(
        max_digits=10,
        decimal_places=2,
        min_value=Decimal("0"),
        required=False,
        allow_null=True,
    )
    retainer_carried_hours = serializers.DecimalField(
        max_digits=10, decimal_places=2, min_value=Decimal("0"), required=False
    )
    description = serializers.CharField(
        required=False, allow_blank=True, allow_null=True
    )

    class Meta:
        model = Project
        fields = (
            "name",
            "account",
            "deal",
            "status",
            "billing_type",
            "currency",
            "budget_hours",
            "budget_amount",
            "hourly_rate",
            *RETAINER_FIELDS,
            "start_date",
            "due_date",
            "description",
        )

    def __init__(self, *args, profile=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.profile = profile
        # No profile only when the schema generator builds this; it then
        # resolves nothing.
        org = profile.org if profile else None
        self.fields["account"].queryset = Account.objects.filter(org=org)
        self.fields["account"].error_messages["does_not_exist"] = "No such account."
        self.fields["deal"].queryset = Opportunity.objects.filter(org=org)
        self.fields["deal"].error_messages["does_not_exist"] = "No such deal."
        if profile is not None and not is_org_admin(profile):
            locked = ADMIN_ONLY_FIELDS
            if self.instance is not None:
                locked += ("account",)
            # A retainer's status decides the months it bills. Billing type
            # is locked too, so a retainer before the write is one after it.
            if getattr(self.instance, "billing_type", None) == RETAINER:
                locked += ("status",)
            for name in locked:
                self.fields.pop(name)

    def validate_name(self, value):
        value = (value or "").strip()
        if not value:
            raise serializers.ValidationError("A project needs a name.")
        return value

    def validate_account(self, account):
        # The account a project already has is kept whoever saves; any other
        # must be one the caller may open, and a refusal reads as unknown.
        if self.instance is not None and account.pk == self.instance.account_id:
            return account
        if not has_account_access(self.profile, account):
            raise serializers.ValidationError("No such account.")
        return account

    def validate_deal(self, deal):
        if deal is None:
            return None
        if self.instance is not None and deal.pk == self.instance.deal_id:
            return deal
        if not module_is_available(self.profile.org, "deals"):
            raise serializers.ValidationError(
                module_off_message(self.profile.org, "deals")
            )
        if not has_deal_access(self.profile, deal):
            raise serializers.ValidationError("No such deal.")
        return deal

    def validate_description(self, value):
        return value or ""

    def validate(self, attrs):
        start = attrs.get("start_date", getattr(self.instance, "start_date", None))
        due = attrs.get("due_date", getattr(self.instance, "due_date", None))
        if start and due and due < start:
            raise serializers.ValidationError(
                {"due_date": "The due date cannot be before the start date."}
            )
        if not attrs.get("currency") and (self.instance is None or "currency" in attrs):
            attrs["currency"] = (
                self.instance.currency
                if self.instance
                else org_currency(self.profile.org)
            )
        self._check_retainer(attrs)
        project = self.instance
        if (
            project is not None
            and attrs.get("currency", project.currency) != project.currency
            and (project.time_entries.exists() or project.invoices.exists())
        ):
            raise serializers.ValidationError(
                {
                    "currency": (
                        "The currency cannot change once the project has time or "
                        "invoices."
                    )
                }
            )
        return attrs

    def _check_retainer(self, attrs):
        def saved(name):
            return attrs[name] if name in attrs else getattr(self.instance, name, None)

        if saved("billing_type") != RETAINER:
            return
        errors = {}
        if saved("retainer_fee") is None:
            errors["retainer_fee"] = ["Set the monthly fee."]
        if (
            saved("retainer_hours") is not None
            and saved("retainer_overage_rate") is None
        ):
            errors["retainer_overage_rate"] = [
                "Set the rate for hours over the allowance."
            ]
        if errors:
            raise serializers.ValidationError(errors)


class _RateBodySerializer(serializers.Serializer):
    profile = serializers.UUIDField()
    hourly_rate = serializers.DecimalField(max_digits=10, decimal_places=2)


class ProjectBodySerializer(ProjectWriteSerializer):
    """The whole write body, for the API schema only."""

    assigned_to = serializers.ListField(child=serializers.UUIDField(), required=False)
    tags = serializers.ListField(child=serializers.UUIDField(), required=False)
    rates = _RateBodySerializer(many=True, required=False)
    custom_fields = serializers.DictField(required=False)

    class Meta(ProjectWriteSerializer.Meta):
        fields = ProjectWriteSerializer.Meta.fields + (
            "assigned_to",
            "tags",
            "rates",
            "custom_fields",
        )


def _decoded(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (TypeError, ValueError):
            return value
    return value


def active_members(org, ids, field, keep=()):
    """The profiles of ``org`` with these ids, each active unless its id is in
    ``keep`` (people already on the project, sent back by an edit form after
    they were deactivated). Anything else is a 400 that names the person, or
    no one for an id outside the org, and never echoes an id."""
    ids = [str(uuid.UUID(str(i))) for i in ids]
    keep = {str(i) for i in keep}
    found = {
        str(p.pk): p
        for p in Profile.objects.filter(org=org, id__in=ids).select_related("user")
    }
    errors = []
    for i in dict.fromkeys(ids):
        person = found.get(i)
        if person is None:
            errors.append("Choose people who are members of this organization.")
        elif not person.is_active and i not in keep:
            name = person.user.name or person.user.email
            errors.append(f"{name} is not an active member of this organization.")
    if errors:
        raise serializers.ValidationError({field: list(dict.fromkeys(errors))})
    return [found[i] for i in ids]


_RATE = serializers.DecimalField(
    max_digits=10, decimal_places=2, min_value=Decimal("0")
)


def parse_rates(org, value, keep=()):
    """``[(profile, rate)]`` from ``[{"profile", "hourly_rate"}]``, or a 400.
    ``keep`` is as in `active_members`."""
    value = _decoded(value)
    if value is None:
        return []
    if not isinstance(value, list):
        raise serializers.ValidationError({"rates": ["Send a list of rates."]})
    ids, amounts = [], []
    for row in value:
        if not isinstance(row, dict) or "profile" not in row:
            raise serializers.ValidationError(
                {"rates": ["Each rate needs a profile and an hourly_rate."]}
            )
        ids.append(str(uuid.UUID(str(validate_uuid(row["profile"], "rates")))))
        try:
            amounts.append(_RATE.run_validation(row.get("hourly_rate")))
        except serializers.ValidationError as exc:
            raise serializers.ValidationError({"rates": exc.detail}) from None
    if len(set(ids)) != len(ids):
        raise serializers.ValidationError(
            {"rates": ["Send at most one rate per person."]}
        )
    return list(zip(active_members(org, ids, "rates", keep), amounts))


def replace_rates(project, rates):
    project.rates.all().delete()
    ProjectRate.objects.bulk_create(
        ProjectRate(org_id=project.org_id, project=project, profile=p, hourly_rate=r)
        for p, r in rates
    )
