"""Org-scoped global search behind ``GET /api/search/?q=``, the ⌘K palette.

ONE endpoint, deliberately. The org comes from the JWT (`request.profile.org`)
exactly once and every queryset is filtered by it; a per-model fan-out from the
browser would be as many chances to read another tenant's rows.

The types searched are the object registry's: each entry of `all_objects(org)`
answers through its `search` part, so an off module is never searched and an
installed app's objects join through their own entries. Every function here
starts from its module's own read rule (`visible_*_qs`), the one its detail
view uses, so search can never surface a record the caller could not open, or
hide one they could. The knowledge base is not a record object and stays in
`NON_OBJECT_SEARCH_SOURCES`.

Matching stays on the server; the whole record set never reaches the browser.
"""

from django.db.models import Q
from drf_spectacular.utils import extend_schema, inline_serializer
from rest_framework import serializers
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from accounts.access import visible_accounts_qs
from cases.access import visible_cases_qs
from cases.models import Solution
from common.modules import module_is_available
from common.object_registry import all_objects
from common.permissions import HasOrgContext
from contacts.access import visible_contacts_qs
from invoices.permissions import visible_invoices_qs
from leads.access import visible_leads_qs
from opportunity.access import visible_deals_qs
from opportunity.stages import stage_index

# Rows per type. Small on purpose. The palette shows a handful per group and
# the point is the fastest match, not an exhaustive report.
PER_TYPE = 6
# One-character queries match almost everything; wait for a second character.
MIN_QUERY = 2


def search_leads(profile, q, limit):
    leads = visible_leads_qs(profile).filter(
        Q(title__icontains=q)
        | Q(first_name__icontains=q)
        | Q(last_name__icontains=q)
        | Q(email__icontains=q)
        | Q(company_name__icontains=q)
    )[:limit]
    hits = []
    for lead in leads:
        name = lead.title or f"{lead.first_name} {lead.last_name}".strip()
        hits.append(
            {
                "type": "lead",
                "id": str(lead.id),
                "title": name or lead.email or "Untitled lead",
                "subtitle": lead.company_name or lead.email or "",
            }
        )
    return hits


def search_deals(profile, q, limit):
    deals = list(
        visible_deals_qs(profile)
        .select_related("account")
        .filter(
            Q(name__icontains=q)
            | Q(description__icontains=q)
            | Q(account__name__icontains=q)
        )[:limit]
    )
    # The label, not the code: stages are configurable per pipeline. One read
    # of the org's stages serves every row.
    stages = stage_index(profile.org_id) if deals else {}
    hits = []
    for deal in deals:
        stage = deal.current_stage(stages)
        hits.append(
            {
                "type": "deal",
                "id": str(deal.id),
                "title": deal.name,
                "subtitle": (deal.account.name if deal.account_id else "")
                or (stage.label if stage else deal.stage)
                or "",
            }
        )
    return hits


def search_accounts(profile, q, limit):
    accounts = visible_accounts_qs(profile).filter(
        Q(name__icontains=q)
        | Q(email__icontains=q)
        | Q(website__icontains=q)
        | Q(industry__icontains=q)
    )[:limit]
    return [
        {
            "type": "account",
            "id": str(account.id),
            "title": account.name,
            "subtitle": account.email or account.industry or "",
        }
        for account in accounts
    ]


def search_contacts(profile, q, limit):
    contacts = visible_contacts_qs(profile).filter(
        Q(first_name__icontains=q)
        | Q(last_name__icontains=q)
        | Q(email__icontains=q)
        | Q(organization__icontains=q)
    )[:limit]
    hits = []
    for contact in contacts:
        name = f"{contact.first_name} {contact.last_name}".strip()
        hits.append(
            {
                "type": "contact",
                "id": str(contact.id),
                "title": name or contact.email or "Unnamed contact",
                "subtitle": contact.organization or contact.email or "",
            }
        )
    return hits


def search_tickets(profile, q, limit):
    cases = (
        visible_cases_qs(profile)
        .select_related("account")
        .filter(
            Q(name__icontains=q)
            | Q(description__icontains=q)
            | Q(account__name__icontains=q)
        )[:limit]
    )
    return [
        {
            "type": "ticket",
            "id": str(case.id),
            "title": case.name,
            "subtitle": (case.account.name if case.account_id else "")
            or case.status
            or "",
        }
        for case in cases
    ]


def search_invoices(profile, q, limit):
    invoices = (
        visible_invoices_qs(profile)
        .select_related("account")
        .filter(
            Q(invoice_number__icontains=q)
            | Q(invoice_title__icontains=q)
            | Q(client_name__icontains=q)
            | Q(account__name__icontains=q)
        )[:limit]
    )
    return [
        {
            "type": "invoice",
            "id": str(invoice.id),
            "title": invoice.invoice_number or invoice.invoice_title or "Invoice",
            "subtitle": invoice.client_name
            or (invoice.account.name if invoice.account_id else "")
            or invoice.status
            or "",
        }
        for invoice in invoices
    ]


def search_articles(profile, q, limit):
    solutions = Solution.objects.filter(org=profile.org).filter(
        Q(title__icontains=q) | Q(description__icontains=q)
    )[:limit]
    return [
        {
            "type": "solution",
            "id": str(solution.id),
            "title": solution.title,
            "subtitle": solution.status or "",
        }
        for solution in solutions
    ]


# Searched but not record objects, so not in the registry: every member reads
# every article, with no owner or read rule. (group, module, search function)
NON_OBJECT_SEARCH_SOURCES = (("Knowledge base", "knowledge_base", search_articles),)


class GlobalSearchView(APIView):
    """``GET /api/search/?q=<query>``. A handful of matches per record type."""

    permission_classes = (IsAuthenticated, HasOrgContext)

    @extend_schema(
        responses={
            200: inline_serializer(
                name="GlobalSearchResponse",
                fields={
                    "query": serializers.CharField(),
                    "results": inline_serializer(
                        name="GlobalSearchHit",
                        many=True,
                        fields={
                            # lead, deal, account, contact, ticket, invoice,
                            # solution, or an installed object's key
                            "type": serializers.CharField(),
                            "id": serializers.UUIDField(),
                            "title": serializers.CharField(),
                            "subtitle": serializers.CharField(),
                            # The type's plural label, such as "Leads"
                            "group": serializers.CharField(),
                        },
                    ),
                },
            )
        }
    )
    def get(self, request):
        q = (request.query_params.get("q") or "").strip()
        if len(q) < MIN_QUERY:
            return Response({"query": q, "results": []})

        profile = request.profile
        org = profile.org
        results = []
        for entry in all_objects(org):
            for hit in entry.search_hits(profile, q, PER_TYPE) or ():
                results.append({**hit, "group": entry.label_plural})
        for group, module, search in NON_OBJECT_SEARCH_SOURCES:
            if module_is_available(org, module):
                for hit in search(profile, q, PER_TYPE):
                    results.append({**hit, "group": group})

        return Response({"query": q, "results": results})
