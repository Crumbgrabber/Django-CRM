from django.utils import timezone
from rest_framework import serializers

from vendors.access import may_delete_vendor, visible_vendors_qs
from vendors.models import Bill, Vendor


class VendorSerializer(serializers.ModelSerializer):
    can_delete = serializers.SerializerMethodField()

    class Meta:
        model = Vendor
        fields = (
            "id",
            "name",
            "email",
            "phone",
            "website",
            "industry",
            "currency",
            "address_line",
            "city",
            "state",
            "postcode",
            "country",
            "assigned_to",
            "teams",
            "contacts",
            "tags",
            "description",
            "is_active",
            "org",
            "created_at",
            "updated_at",
            "created_by",
            "updated_by",
            "can_delete",
        )
        read_only_fields = (
            "id",
            "org",
            "created_at",
            "updated_at",
            "created_by",
            "updated_by",
        )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        request = self.context.get("request")
        for name in ("assigned_to", "teams", "contacts", "tags"):
            field = self.fields[name].child_relation
            field.queryset = (
                field.queryset.filter(org=request.profile.org)
                if request
                else field.queryset.none()
            )
            self.fields[name].required = False
            self.fields[name].allow_empty = True

    def validate_name(self, value):
        qs = Vendor.objects.filter(
            org=self.context["request"].profile.org, name__iexact=value
        )
        if self.instance:
            qs = qs.exclude(pk=self.instance.pk)
        if qs.exists():
            raise serializers.ValidationError("A vendor with this name already exists.")
        return value

    def get_can_delete(self, obj) -> bool:
        request = self.context.get("request")
        return bool(request and may_delete_vendor(request.profile, obj))


class VendorListResponseSerializer(serializers.Serializer):
    count = serializers.IntegerField()
    next = serializers.URLField(allow_null=True)
    previous = serializers.URLField(allow_null=True)
    results = VendorSerializer(many=True)


class BillSerializer(serializers.ModelSerializer):
    vendor_name = serializers.CharField(source="vendor.name", read_only=True)
    is_overdue = serializers.SerializerMethodField()

    class Meta:
        model = Bill
        fields = (
            "id",
            "vendor",
            "vendor_name",
            "bill_number",
            "bill_date",
            "due_date",
            "currency",
            "total_amount",
            "amount_paid",
            "balance_due",
            "status",
            "is_overdue",
            "notes",
            "org",
            "created_at",
            "updated_at",
            "created_by",
            "updated_by",
        )
        read_only_fields = (
            "id",
            "balance_due",
            "org",
            "created_at",
            "updated_at",
            "created_by",
            "updated_by",
        )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        request = self.context.get("request")
        self.fields["vendor"].queryset = (
            visible_vendors_qs(request.profile) if request else Vendor.objects.none()
        )

    def validate(self, attrs):
        total = attrs.get("total_amount", getattr(self.instance, "total_amount", 0))
        paid = attrs.get("amount_paid", getattr(self.instance, "amount_paid", 0))
        if total < 0 or paid < 0:
            raise serializers.ValidationError("Amounts cannot be negative.")
        if paid > total:
            raise serializers.ValidationError(
                {"amount_paid": "Amount paid cannot be more than the total."}
            )
        bill_date = attrs.get("bill_date", getattr(self.instance, "bill_date", None))
        due_date = attrs.get("due_date", getattr(self.instance, "due_date", None))
        if bill_date and due_date and due_date < bill_date:
            raise serializers.ValidationError(
                {"due_date": "Due date cannot be before the bill date."}
            )
        status = attrs.get("status")
        if status and status not in (Bill.STATUS_VOID, Bill.STATUS_UNPAID):
            # Paid / partly paid follow from the amounts; only void is set by hand.
            attrs.pop("status")
        return attrs

    def get_is_overdue(self, obj) -> bool:
        return bool(
            obj.due_date
            and obj.balance_due > 0
            and obj.status != Bill.STATUS_VOID
            and obj.due_date < timezone.localdate()
        )


class BillListResponseSerializer(serializers.Serializer):
    count = serializers.IntegerField()
    next = serializers.URLField(allow_null=True)
    previous = serializers.URLField(allow_null=True)
    results = BillSerializer(many=True)
