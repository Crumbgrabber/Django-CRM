from django.db import models
from django.db.models import F, Q
from django.utils.translation import gettext_lazy as _

from accounts.models import Account
from common.base import SAMPLE_DATA_HELP_TEXT, BaseOrgModel
from common.models import Profile, Tags
from common.utils import CURRENCY_CODES

STATUS_CHOICES = (
    ("active", "Active"),
    ("on_hold", "On hold"),
    ("completed", "Completed"),
    ("cancelled", "Cancelled"),
)

# What an estimate or a pack may start a project as. A retainer needs its fee
# and months, which only the project form sets (`projects.retainers`).
STARTING_BILLING_TYPES = (
    ("time_and_materials", "Time and materials"),
    ("fixed_fee", "Fixed fee"),
    ("non_billable", "Non-billable"),
)

BILLING_TYPES = STARTING_BILLING_TYPES + (("retainer", "Retainer"),)

# The highest budget level already notified, per kind (see projects.burn).
ALERT_LEVELS = ((0, "None"), (80, "80%"), (100, "100%"))


class Project(BaseOrgModel):
    """Delivery work for a client, between the won deal and the invoice.

    Tasks, time entries and invoices point here with ``SET_NULL``, so deleting
    a project keeps them, unlinked.
    """

    name = models.CharField(_("Name"), max_length=255)
    account = models.ForeignKey(
        Account, on_delete=models.PROTECT, related_name="projects"
    )
    deal = models.ForeignKey(
        "opportunity.Opportunity",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="projects",
    )
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default="active")
    billing_type = models.CharField(
        max_length=20, choices=BILLING_TYPES, default="time_and_materials"
    )
    currency = models.CharField(max_length=3, choices=CURRENCY_CODES, default="USD")
    budget_hours = models.DecimalField(
        max_digits=10, decimal_places=2, null=True, blank=True
    )
    budget_amount = models.DecimalField(
        max_digits=12, decimal_places=2, null=True, blank=True
    )
    hourly_rate = models.DecimalField(
        max_digits=10, decimal_places=2, null=True, blank=True
    )
    start_date = models.DateField(null=True, blank=True)
    due_date = models.DateField(null=True, blank=True)
    assigned_to = models.ManyToManyField(
        Profile, related_name="assigned_projects", blank=True
    )
    tags = models.ManyToManyField(Tags, related_name="projects", blank=True)
    description = models.TextField(blank=True, default="")
    custom_fields = models.JSONField(
        default=dict,
        blank=True,
        help_text="Per-org schema extension; values are validated against common.CustomFieldDefinition.",
    )
    retainer_fee = models.DecimalField(
        max_digits=12, decimal_places=2, null=True, blank=True
    )
    retainer_hours = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        null=True,
        blank=True,
        help_text="Hours each month's fee includes; none means the fee alone.",
    )
    retainer_rollover = models.BooleanField(default=False)
    retainer_overage_rate = models.DecimalField(
        max_digits=10, decimal_places=2, null=True, blank=True
    )
    retainer_carried_hours = models.DecimalField(
        max_digits=10, decimal_places=2, default=0
    )
    retainer_next_month = models.DateField(
        null=True,
        blank=True,
        help_text="First day of the month the next retainer invoice bills.",
    )
    retainer_last_month = models.DateField(
        null=True,
        blank=True,
        help_text="First day of the last month to bill; empty while the retainer is open.",
    )
    hours_alert = models.PositiveSmallIntegerField(choices=ALERT_LEVELS, default=0)
    amount_alert = models.PositiveSmallIntegerField(choices=ALERT_LEVELS, default=0)
    is_sample = models.BooleanField(default=False, help_text=SAMPLE_DATA_HELP_TEXT)

    class Meta:
        verbose_name = "Project"
        verbose_name_plural = "Projects"
        db_table = "project"
        ordering = ("-created_at",)
        indexes = [
            models.Index(fields=["org", "-created_at"]),
            models.Index(fields=["org", "status"]),
        ]
        constraints = [
            models.CheckConstraint(
                condition=Q(budget_hours__gte=0) | Q(budget_hours__isnull=True),
                name="project_budget_hours_non_negative",
            ),
            models.CheckConstraint(
                condition=Q(budget_amount__gte=0) | Q(budget_amount__isnull=True),
                name="project_budget_amount_non_negative",
            ),
            models.CheckConstraint(
                condition=Q(hourly_rate__gte=0) | Q(hourly_rate__isnull=True),
                name="project_hourly_rate_non_negative",
            ),
            models.CheckConstraint(
                condition=Q(retainer_fee__gte=0) | Q(retainer_fee__isnull=True),
                name="project_retainer_fee_non_negative",
            ),
            models.CheckConstraint(
                condition=Q(retainer_hours__gte=0) | Q(retainer_hours__isnull=True),
                name="project_retainer_hours_non_negative",
            ),
            models.CheckConstraint(
                condition=Q(retainer_overage_rate__gte=0)
                | Q(retainer_overage_rate__isnull=True),
                name="project_retainer_overage_rate_non_negative",
            ),
            models.CheckConstraint(
                condition=Q(retainer_carried_hours__gte=0),
                name="project_retainer_carried_hours_non_negative",
            ),
            models.CheckConstraint(
                condition=Q(due_date__isnull=True)
                | Q(start_date__isnull=True)
                | Q(due_date__gte=F("start_date")),
                name="project_due_not_before_start",
            ),
        ]

    def __str__(self):
        return self.name


class ProjectRate(BaseOrgModel):
    """One person's hourly rate on one project, ahead of the project's own."""

    project = models.ForeignKey(Project, on_delete=models.CASCADE, related_name="rates")
    profile = models.ForeignKey(
        Profile, on_delete=models.CASCADE, related_name="project_rates"
    )
    hourly_rate = models.DecimalField(max_digits=10, decimal_places=2)

    class Meta:
        verbose_name = "Project rate"
        verbose_name_plural = "Project rates"
        db_table = "project_rate"
        ordering = ("created_at",)
        indexes = [models.Index(fields=["org", "-created_at"])]
        constraints = [
            models.UniqueConstraint(
                fields=["project", "profile"], name="unique_project_rate_per_profile"
            ),
            models.CheckConstraint(
                condition=Q(hourly_rate__gte=0),
                name="project_rate_non_negative",
            ),
        ]

    def __str__(self):
        return f"{self.project_id}: {self.profile_id} at {self.hourly_rate}"
