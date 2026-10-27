import uuid

from django.db import IntegrityError, transaction
from django.db.models import ProtectedError
from django.utils import timezone
from drf_spectacular.utils import OpenApiParameter, extend_schema
from rest_framework import status
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.pagination import LimitOffsetPagination
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from common.lookups import get_scoped_or_404
from common.module_deletes import delete_refusal
from common.permissions import HasOrgContext
from vendors.access import may_delete_vendor, visible_bills_qs, visible_vendors_qs
from vendors.models import Bill, Vendor
from vendors.serializers import (
    BillListResponseSerializer,
    BillSerializer,
    VendorListResponseSerializer,
    VendorSerializer,
)


def save_vendor(serializer, **kwargs):
    try:
        with transaction.atomic():
            serializer.save(**kwargs)
    except IntegrityError:
        name = serializer.validated_data.get(
            "name", getattr(serializer.instance, "name", "")
        )
        duplicates = Vendor.objects.filter(org=kwargs["org"], name__iexact=name)
        if serializer.instance:
            duplicates = duplicates.exclude(pk=serializer.instance.pk)
        if not duplicates.exists():
            raise
        raise ValidationError(
            {"name": "A vendor with this name already exists."}
        ) from None


class VendorListView(APIView):
    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        responses=VendorListResponseSerializer,
        parameters=[
            OpenApiParameter("search", str),
            OpenApiParameter("limit", int),
            OpenApiParameter("offset", int),
        ],
    )
    def get(self, request):
        qs = visible_vendors_qs(request.profile).prefetch_related(
            "assigned_to", "teams", "contacts", "tags"
        )
        search = request.query_params.get("search", "").strip()
        if search:
            qs = qs.filter(name__icontains=search)
        paginator = LimitOffsetPagination()
        paginator.default_limit = 25
        paginator.max_limit = 100
        rows = paginator.paginate_queryset(qs, request, view=self)
        return paginator.get_paginated_response(
            VendorSerializer(rows, many=True, context={"request": request}).data
        )

    @extend_schema(request=VendorSerializer, responses={201: VendorSerializer})
    def post(self, request):
        serializer = VendorSerializer(data=request.data, context={"request": request})
        serializer.is_valid(raise_exception=True)
        save_vendor(serializer, org=request.profile.org, created_by=request.user)
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class VendorDetailView(APIView):
    permission_classes = (IsAuthenticated, HasOrgContext)

    def get_object(self, request, pk):
        return get_scoped_or_404(
            Vendor,
            pk,
            request.profile.org,
            id__in=visible_vendors_qs(request.profile).values("id"),
        )

    @extend_schema(responses=VendorSerializer)
    def get(self, request, pk):
        return Response(
            VendorSerializer(
                self.get_object(request, pk), context={"request": request}
            ).data
        )

    def update(self, request, pk, partial):
        serializer = VendorSerializer(
            self.get_object(request, pk),
            data=request.data,
            partial=partial,
            context={"request": request},
        )
        serializer.is_valid(raise_exception=True)
        save_vendor(serializer, org=request.profile.org)
        return Response(serializer.data)

    @extend_schema(request=VendorSerializer, responses=VendorSerializer)
    def put(self, request, pk):
        return self.update(request, pk, False)

    @extend_schema(request=VendorSerializer, responses=VendorSerializer)
    def patch(self, request, pk):
        return self.update(request, pk, True)

    @extend_schema(responses={204: None})
    def delete(self, request, pk):
        vendor = self.get_object(request, pk)
        if not may_delete_vendor(request.profile, vendor):
            raise PermissionDenied("You may not delete this vendor.")
        refusal = delete_refusal(vendor, "This vendor")
        if refusal:
            return Response(refusal, status=status.HTTP_409_CONFLICT)
        try:
            vendor.delete()
        except ProtectedError:
            raise ValidationError(
                "This vendor has bills. Delete its bills first, or mark the vendor inactive."
            ) from None
        return Response(status=status.HTTP_204_NO_CONTENT)


class BillListView(APIView):
    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        responses=BillListResponseSerializer,
        parameters=[
            OpenApiParameter("vendor", str),
            OpenApiParameter("status", str),
            OpenApiParameter("overdue", bool),
            OpenApiParameter("limit", int),
            OpenApiParameter("offset", int),
        ],
    )
    def get(self, request):
        qs = visible_bills_qs(request.profile).select_related("vendor")
        params = request.query_params
        if params.get("vendor"):
            try:
                qs = qs.filter(vendor_id=uuid.UUID(params["vendor"]))
            except ValueError:
                raise ValidationError({"vendor": "Not a valid vendor id."}) from None
        if params.get("status"):
            qs = qs.filter(status=params["status"])
        if params.get("overdue") in ("1", "true"):
            qs = qs.filter(
                due_date__lt=timezone.localdate(), balance_due__gt=0
            ).exclude(status=Bill.STATUS_VOID)
        paginator = LimitOffsetPagination()
        paginator.default_limit = 25
        paginator.max_limit = 100
        rows = paginator.paginate_queryset(qs, request, view=self)
        return paginator.get_paginated_response(
            BillSerializer(rows, many=True, context={"request": request}).data
        )

    @extend_schema(request=BillSerializer, responses={201: BillSerializer})
    def post(self, request):
        serializer = BillSerializer(data=request.data, context={"request": request})
        serializer.is_valid(raise_exception=True)
        serializer.save(org=request.profile.org, created_by=request.user)
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class BillDetailView(APIView):
    permission_classes = (IsAuthenticated, HasOrgContext)

    def get_object(self, request, pk):
        return get_scoped_or_404(
            Bill,
            pk,
            request.profile.org,
            id__in=visible_bills_qs(request.profile).values("id"),
        )

    @extend_schema(responses=BillSerializer)
    def get(self, request, pk):
        return Response(
            BillSerializer(
                self.get_object(request, pk), context={"request": request}
            ).data
        )

    def update(self, request, pk, partial):
        serializer = BillSerializer(
            self.get_object(request, pk),
            data=request.data,
            partial=partial,
            context={"request": request},
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)

    @extend_schema(request=BillSerializer, responses=BillSerializer)
    def put(self, request, pk):
        return self.update(request, pk, False)

    @extend_schema(request=BillSerializer, responses=BillSerializer)
    def patch(self, request, pk):
        return self.update(request, pk, True)

    @extend_schema(responses={204: None})
    def delete(self, request, pk):
        bill = self.get_object(request, pk)
        if not may_delete_vendor(request.profile, bill.vendor):
            raise PermissionDenied("You may not delete this bill.")
        bill.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)
