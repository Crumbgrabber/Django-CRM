"""Who may open, edit and delete a project: the deal rules (`opportunity.access`).

A project the caller may not open answers exactly as an id that does not
exist, so views look it up through `visible_projects_qs` in one step.
"""

from django.db.models import Q

from common.permissions import is_org_admin
from projects.models import Project


def has_project_access(profile, project):
    """Admins, the creator and anyone assigned may read and edit."""
    if is_org_admin(profile):
        return True
    if profile.user_id == project.created_by_id:
        return True
    return project.assigned_to.filter(pk=profile.pk).exists()


def may_delete_project(profile, project):
    """Admins and the creator; an assignee may edit but not delete."""
    return is_org_admin(profile) or profile.user_id == project.created_by_id


def may_bill_project(profile):
    return is_org_admin(profile)


def visible_projects_qs(profile):
    """Projects ``profile`` may open, the queryset form of `has_project_access`."""
    qs = Project.objects.filter(org=profile.org)
    if is_org_admin(profile):
        return qs
    return qs.filter(Q(created_by=profile.user) | Q(assigned_to=profile)).distinct()


def get_visible_project(profile, pk):
    """The project ``pk`` if ``profile`` may open it, else ``None`` for a hidden
    and a missing one alike."""
    return visible_projects_qs(profile).filter(pk=pk).first()
