from django.db.models import Q

from common.permissions import is_org_admin
from vendors.models import Vendor


def has_vendor_access(profile, vendor):
    return (
        is_org_admin(profile)
        or profile.user_id == vendor.created_by_id
        or vendor.assigned_to.filter(pk=profile.pk).exists()
    )


def may_delete_vendor(profile, vendor):
    return is_org_admin(profile) or profile.user_id == vendor.created_by_id


def visible_vendors_qs(profile):
    qs = Vendor.objects.filter(org=profile.org)
    if is_org_admin(profile):
        return qs
    return qs.filter(Q(created_by=profile.user) | Q(assigned_to=profile)).distinct()


def visible_bills_qs(profile):
    from vendors.models import Bill

    return Bill.objects.filter(
        org=profile.org, vendor__in=visible_vendors_qs(profile).values("id")
    )
