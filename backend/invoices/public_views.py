"""
Public views for client portal.

These views do not require authentication and are accessed via public tokens.
"""

import logging

from django.core.exceptions import ValidationError
from django.core.validators import validate_email
from django.db import transaction
from django.http import HttpResponse
from django.utils import timezone
from django.utils.decorators import method_decorator
from drf_spectacular.types import OpenApiTypes
from drf_spectacular.utils import extend_schema, inline_serializer
from rest_framework import serializers, status
from rest_framework.response import Response
from rest_framework.views import APIView

from common.models import Org
from common.modules import module_is_available
from common.org_time import activate_org_timezone
from common.portal_tokens import resolve_portal_org
from common.request_meta import client_ip, user_agent
from common.tasks import set_rls_context
from invoices.models import Estimate, Invoice, InvoiceTemplate
from invoices.pdf import (
    generate_estimate_filename,
    generate_estimate_pdf,
    generate_invoice_filename,
    generate_invoice_pdf,
)
from invoices.proposals import (
    estimate_deposit,
    notify_accepted,
    notify_declined,
    start_on_acceptance,
)
from invoices.serializer import EstimateDepositSerializer

logger = logging.getLogger(__name__)


def _text(*names, **kwargs):
    return {name: serializers.CharField(**kwargs) for name in names}


_LINES = inline_serializer(
    "PublicDocumentLine",
    _text("name", "description", "quantity", "unit_price", "amount"),
    many=True,
)
_ORG = inline_serializer("PublicDocumentOrg", _text("name", allow_null=True))
_STYLE = inline_serializer(
    "PublicDocumentStyle", _text("primary_color", "secondary_color", "footer_text")
)


def _document(name, fields):
    """The schema of a public invoice or estimate body. Amounts are strings."""
    return inline_serializer(
        name, {**fields, "line_items": _LINES, "org": _ORG, "template": _STYLE}
    )


def _address(name):
    return inline_serializer(
        name, _text("line", "city", "state", "postcode", "country")
    )


_AMOUNTS = (
    "subtotal",
    "discount_value",
    "discount_amount",
    "tax_rate",
    "tax_amount",
    "total_amount",
)
_PUBLIC_INVOICE = _document(
    "PublicInvoice",
    {
        **_text("id", "invoice_number", "invoice_title", "status"),
        **_text("client_name", "client_email", "discount_type", "currency"),
        **_text("notes", "terms", *_AMOUNTS),
        **_text("shipping_amount", "amount_paid", "amount_due"),
        "issue_date": serializers.DateField(),
        "due_date": serializers.DateField(allow_null=True),
        "billing_address": _address("PublicInvoiceAddress"),
        "payments": inline_serializer(
            "PublicInvoicePayment",
            {
                "amount": serializers.CharField(),
                "payment_date": serializers.DateField(),
                "payment_method": serializers.CharField(),
            },
            many=True,
        ),
    },
)
_PUBLIC_ESTIMATE = _document(
    "PublicEstimate",
    {
        **_text("id", "estimate_number", "title", "status"),
        **_text("client_name", "client_email", "discount_type", "currency"),
        **_text("notes", "terms", "introduction", *_AMOUNTS),
        "issue_date": serializers.DateField(),
        "expiry_date": serializers.DateField(allow_null=True),
        "client_address": _address("PublicEstimateAddress"),
        "deposit": EstimateDepositSerializer(allow_null=True),
    },
)
_PUBLIC_MESSAGE = inline_serializer(
    "PublicEstimateDecisionResponse",
    {"error": serializers.BooleanField(), "message": serializers.CharField()},
)


def _resolve_org_context(token, resource_type):
    """Resolve the org from the URL token and set RLS context for this request.

    Public endpoints reach the view with an empty ``app.current_org`` (the
    middleware exempts them but sets no context), so under a correctly-configured
    non-superuser DB role the resource query below would match zero rows and 404
    every customer. Resolving the org from the unscoped token lookup and setting
    the context first lets the query run under full RLS.

    An unknown token leaves the context empty; the scoped query then returns
    nothing and the caller 404s. The same answer a disabled link gives, so a
    stranger learns nothing about whether a token is real.

    The org's timezone is activated too. No user is signed in, so the
    middleware found no org and left the server's UTC day active, and every
    day check below (an estimate's expiry, the PDF's "(Expired)" and year)
    would have run on it. `GetProfileAndOrg` deactivates it when the request
    ends, so it cannot reach the next request on this worker.
    """
    org_id = resolve_portal_org(token, resource_type)
    if org_id:
        set_rls_context(org_id)
        activate_org_timezone(Org.objects.filter(id=org_id).first())
    return org_id


class PublicInvoiceView(APIView):
    """
    Public view for invoice - accessible via public token.
    No authentication required.
    """

    authentication_classes = []
    permission_classes = []

    @extend_schema(tags=["Public"], responses=_PUBLIC_INVOICE)
    def get(self, request, token):
        """Get invoice by public token"""
        _resolve_org_context(token, "invoice")
        invoice = Invoice.objects.filter(
            public_token=token, public_link_enabled=True
        ).first()

        if not invoice or not module_is_available(invoice.org, "invoices"):
            return Response(
                {"error": True, "message": "Invoice not found or link expired"},
                status=status.HTTP_404_NOT_FOUND,
            )

        # Track view if first time. Re-read under a row lock and write only
        # these fields, so a staff edit or payment that commits meanwhile
        # survives and the Sent check reads the status as it is now.
        if not invoice.viewed_at:
            with transaction.atomic():
                invoice = Invoice.objects.select_for_update().get(pk=invoice.pk)
                if not invoice.viewed_at:
                    invoice.viewed_at = timezone.now()
                    if invoice.status == "Sent":
                        invoice.status = "Viewed"
                    invoice.save(update_fields=["viewed_at", "status", "updated_at"])

        # Serialize invoice data for public view
        data = {
            "id": str(invoice.id),
            "invoice_number": invoice.invoice_number,
            "invoice_title": invoice.invoice_title,
            "status": invoice.status,
            "client_name": invoice.client_name,
            "client_email": invoice.client_email,
            "issue_date": invoice.issue_date,
            "due_date": invoice.due_date,
            "subtotal": str(invoice.subtotal),
            "discount_type": invoice.discount_type,
            "discount_value": str(invoice.discount_value),
            "discount_amount": str(invoice.discount_amount),
            "tax_rate": str(invoice.tax_rate),
            "tax_amount": str(invoice.tax_amount),
            "shipping_amount": str(invoice.shipping_amount),
            "total_amount": str(invoice.total_amount),
            "amount_paid": str(invoice.amount_paid),
            "amount_due": str(invoice.amount_due),
            "currency": invoice.currency,
            "notes": invoice.notes,
            "terms": invoice.terms,
            "billing_address": {
                "line": invoice.billing_address_line,
                "city": invoice.billing_city,
                "state": invoice.billing_state,
                "postcode": invoice.billing_postcode,
                "country": invoice.billing_country,
            },
            "line_items": [
                {
                    "name": item.name or "",
                    "description": item.description,
                    "quantity": str(item.quantity),
                    "unit_price": str(item.unit_price),
                    # net_amount, after the line's own discount: the lines add
                    # up to "subtotal" above.
                    "amount": str(item.net_amount),
                }
                for item in invoice.line_items.all().order_by("order")
            ],
            "payments": [
                {
                    "amount": str(payment.amount),
                    "payment_date": payment.payment_date,
                    "payment_method": payment.payment_method,
                }
                for payment in invoice.payments.all().order_by("-payment_date")
            ],
            "org": {
                "name": invoice.org.name if invoice.org else "",
            },
        }

        # Get default template for styling
        template = invoice.template
        if not template and invoice.org:
            template = InvoiceTemplate.objects.filter(
                org=invoice.org, is_default=True
            ).first()

        if template:
            data["template"] = {
                "primary_color": template.primary_color,
                "secondary_color": template.secondary_color,
                "footer_text": template.footer_text or "",
            }
        else:
            data["template"] = {
                "primary_color": "#3B82F6",
                "secondary_color": "#1E40AF",
                "footer_text": "",
            }

        return Response(data)


class PublicInvoicePDFView(APIView):
    """
    Public PDF download for invoice - accessible via public token.
    No authentication required.
    """

    authentication_classes = []
    permission_classes = []

    @extend_schema(
        tags=["Public"], responses={(200, "application/pdf"): OpenApiTypes.BINARY}
    )
    def get(self, request, token):
        """Download invoice PDF by public token"""
        _resolve_org_context(token, "invoice")
        invoice = Invoice.objects.filter(
            public_token=token, public_link_enabled=True
        ).first()

        if not invoice or not module_is_available(invoice.org, "invoices"):
            return Response(
                {"error": True, "message": "Invoice not found or link expired"},
                status=status.HTTP_404_NOT_FOUND,
            )

        try:
            pdf_content = generate_invoice_pdf(invoice, include_payments=True)
            filename = generate_invoice_filename(invoice)

            response = HttpResponse(pdf_content, content_type="application/pdf")
            response["Content-Disposition"] = f'attachment; filename="{filename}"'
            return response
        except ImportError:
            logger.exception("PDF generation library not available")
            return Response(
                {"error": True, "message": "PDF generation unavailable"},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        except Exception:
            logger.exception("Failed to generate invoice PDF")
            return Response(
                {"error": True, "message": "Failed to generate PDF"},
                status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )


class PublicEstimateView(APIView):
    """
    Public view for estimate - accessible via public token.
    No authentication required.
    """

    authentication_classes = []
    permission_classes = []

    @extend_schema(tags=["Public"], responses=_PUBLIC_ESTIMATE)
    def get(self, request, token):
        """Get estimate by public token"""
        _resolve_org_context(token, "estimate")
        estimate = Estimate.objects.filter(
            public_token=token, public_link_enabled=True
        ).first()

        if not estimate or not module_is_available(estimate.org, "invoices"):
            return Response(
                {"error": True, "message": "Estimate not found or link expired"},
                status=status.HTTP_404_NOT_FOUND,
            )

        # Track view if first time, locked and narrow as on an invoice.
        if not estimate.viewed_at:
            with transaction.atomic():
                estimate = Estimate.objects.select_for_update().get(pk=estimate.pk)
                if not estimate.viewed_at:
                    estimate.viewed_at = timezone.now()
                    if estimate.status == "Sent":
                        estimate.status = "Viewed"
                    estimate.save(update_fields=["viewed_at", "status", "updated_at"])

        # Serialize estimate data for public view
        data = {
            "id": str(estimate.id),
            "estimate_number": estimate.estimate_number,
            "title": estimate.title,
            "status": estimate.status,
            "client_name": estimate.client_name,
            "client_email": estimate.client_email,
            "issue_date": estimate.issue_date,
            "expiry_date": estimate.expiry_date,
            "subtotal": str(estimate.subtotal),
            "discount_type": estimate.discount_type,
            "discount_value": str(estimate.discount_value),
            "discount_amount": str(estimate.discount_amount),
            "tax_rate": str(estimate.tax_rate),
            "tax_amount": str(estimate.tax_amount),
            "total_amount": str(estimate.total_amount),
            "currency": estimate.currency,
            "notes": estimate.notes,
            "terms": estimate.terms,
            "introduction": estimate.introduction or "",
            "deposit": estimate_deposit(estimate),
            "client_address": {
                "line": estimate.client_address_line,
                "city": estimate.client_city,
                "state": estimate.client_state,
                "postcode": estimate.client_postcode,
                "country": estimate.client_country,
            },
            "line_items": [
                {
                    "name": item.name or "",
                    "description": item.description,
                    "quantity": str(item.quantity),
                    "unit_price": str(item.unit_price),
                    # net_amount, after the line's own discount: the lines add
                    # up to "subtotal" above.
                    "amount": str(item.net_amount),
                }
                for item in estimate.line_items.all().order_by("order")
            ],
            "org": {
                "name": estimate.org.name if estimate.org else "",
            },
        }

        # Get default template for styling
        if estimate.org:
            template = InvoiceTemplate.objects.filter(
                org=estimate.org, is_default=True
            ).first()
        else:
            template = None

        if template:
            data["template"] = {
                "primary_color": template.primary_color,
                "secondary_color": template.secondary_color,
                "footer_text": template.footer_text or "",
            }
        else:
            data["template"] = {
                "primary_color": "#3B82F6",
                "secondary_color": "#1E40AF",
                "footer_text": "",
            }

        return Response(data)


class PublicEstimatePDFView(APIView):
    """
    Public PDF download for estimate - accessible via public token.
    No authentication required.
    """

    authentication_classes = []
    permission_classes = []

    @extend_schema(
        tags=["Public"], responses={(200, "application/pdf"): OpenApiTypes.BINARY}
    )
    def get(self, request, token):
        """Download estimate PDF by public token"""
        _resolve_org_context(token, "estimate")
        estimate = Estimate.objects.filter(
            public_token=token, public_link_enabled=True
        ).first()

        if not estimate or not module_is_available(estimate.org, "invoices"):
            return Response(
                {"error": True, "message": "Estimate not found or link expired"},
                status=status.HTTP_404_NOT_FOUND,
            )

        try:
            pdf_content = generate_estimate_pdf(estimate)
            filename = generate_estimate_filename(estimate)

            response = HttpResponse(pdf_content, content_type="application/pdf")
            response["Content-Disposition"] = f'attachment; filename="{filename}"'
            return response
        except ImportError:
            logger.exception("PDF generation library not available")
            return Response(
                {"error": True, "message": "PDF generation unavailable"},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        except Exception:
            logger.exception("Failed to generate estimate PDF")
            return Response(
                {"error": True, "message": "Failed to generate PDF"},
                status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )


class PublicEstimateAcceptView(APIView):
    """
    Public endpoint to accept an estimate - accessible via public token.
    No authentication required.
    """

    authentication_classes = []
    permission_classes = []

    @extend_schema(
        tags=["Public"],
        request=inline_serializer(
            "PublicEstimateAccept",
            {"name": serializers.CharField(), "email": serializers.EmailField()},
        ),
        responses=_PUBLIC_MESSAGE,
    )
    @method_decorator(transaction.atomic)
    def post(self, request, token):
        """Accept estimate by public token.

        Accepting a quote authorises its price, so this is enforced, not
        cosmetic: the token holder must be within the estimate's validity
        window and must identify themselves. Both checks live here because the
        frontend is not a trust boundary, hiding the button past expiry, or
        collecting a name the client could omit, protects nothing.

        The row is locked from the read to the save, so the status and expiry
        checks judge the estimate as it is when accepted, and a staff edit
        that commits meanwhile is not written back over. The project and
        deposit invoice it starts are made in the same transaction, so a
        failure answers 500 with nothing accepted or made.
        """
        _resolve_org_context(token, "estimate")
        estimate = (
            Estimate.objects.select_for_update()
            .filter(public_token=token, public_link_enabled=True)
            .first()
        )

        if not estimate or not module_is_available(estimate.org, "invoices"):
            return Response(
                {"error": True, "message": "Estimate not found or link expired"},
                status=status.HTTP_404_NOT_FOUND,
            )

        if estimate.status not in ["Sent", "Viewed"]:
            return Response(
                {
                    "error": True,
                    "message": "Estimate cannot be accepted in current state",
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        # An expired quote is not acceptable at its original price. expiry_date
        # is stored and printed on the estimate but was previously enforced
        # nowhere; the check belongs on the server.
        if estimate.is_expired:
            return Response(
                {
                    "error": True,
                    "message": (
                        f"This estimate expired on {estimate.expiry_date} and can "
                        "no longer be accepted. Please request an updated quote."
                    ),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Acceptance is an authorisation; record who gave it. Name and a valid
        # email are required so the record is more than "whoever held the link".
        name = (request.data.get("name") or "").strip()
        email = (request.data.get("email") or "").strip()
        if not name or not email:
            return Response(
                {
                    "error": True,
                    "message": "Your name and email are required to accept this estimate.",
                },
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            validate_email(email)
        except ValidationError:
            return Response(
                {"error": True, "message": "Please enter a valid email address."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        estimate.status = "Accepted"
        estimate.accepted_at = timezone.now()
        estimate.accepted_by_name = name[:255]
        estimate.accepted_by_email = email[:254]
        estimate.accepted_ip = client_ip(request)
        estimate.accepted_user_agent = user_agent(request)[:1024]
        start_on_acceptance(estimate)
        estimate.save(
            update_fields=[
                "status",
                "accepted_at",
                "accepted_by_name",
                "accepted_by_email",
                "accepted_ip",
                "accepted_user_agent",
                "project",
                "deposit_invoice",
                "updated_at",
            ]
        )
        notify_accepted(estimate)

        return Response({"error": False, "message": "Estimate accepted successfully"})


class PublicEstimateDeclineView(APIView):
    """
    Public endpoint to decline an estimate - accessible via public token.
    No authentication required.
    """

    authentication_classes = []
    permission_classes = []

    @extend_schema(tags=["Public"], request=None, responses=_PUBLIC_MESSAGE)
    @method_decorator(transaction.atomic)
    def post(self, request, token):
        """Decline estimate by public token, locked as accept is."""
        _resolve_org_context(token, "estimate")
        estimate = (
            Estimate.objects.select_for_update()
            .filter(public_token=token, public_link_enabled=True)
            .first()
        )

        if not estimate or not module_is_available(estimate.org, "invoices"):
            return Response(
                {"error": True, "message": "Estimate not found or link expired"},
                status=status.HTTP_404_NOT_FOUND,
            )

        if estimate.status not in ["Sent", "Viewed"]:
            return Response(
                {
                    "error": True,
                    "message": "Estimate cannot be declined in current state",
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        estimate.status = "Declined"
        estimate.declined_at = timezone.now()
        estimate.save(update_fields=["status", "declined_at", "updated_at"])
        notify_declined(estimate)

        return Response({"error": False, "message": "Estimate declined"})
