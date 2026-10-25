"""Time entry rules that belong to projects: the rate that fills itself and
the optional task an entry names."""

from rest_framework import serializers

from common.validators import validate_uuid
from tasks.access import visible_tasks_qs


def rate_for(project, profile):
    """The person's rate on the project, else the project's, else None."""
    own = (
        project.rates.filter(profile=profile)
        .values_list("hourly_rate", flat=True)
        .first()
    )
    return own if own is not None else project.hourly_rate


def billable_on(project, sent):
    """Whether time on ``project`` is billable: never on a non-billable
    project, else what was sent, else yes."""
    if project.billing_type == "non_billable":
        return False
    return True if sent is None else sent


def task_on_project(project, data, profile):
    """The task ``data["task"]`` names, which must be on ``project`` and one
    ``profile`` may open; ``None`` when the body names none. Anything else is
    a 400."""
    value = data.get("task") if hasattr(data, "get") else None
    if value in (None, ""):
        return None
    validate_uuid(value, "task")
    task = visible_tasks_qs(profile).filter(pk=value, project=project).first()
    if task is None:
        raise serializers.ValidationError({"task": ["Choose a task on this project."]})
    return task
