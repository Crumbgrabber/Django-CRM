from django.db import models
from django.db.models.functions import Lower
from django.utils.translation import gettext_lazy as _

from common.base import AssignableMixin, BaseOrgModel
from common.models import Profile, Tags, Teams
from common.utils import COUNTRIES, CURRENCY_CODES, INDCHOICES
from common.validators import flexible_phone_validator


class Vendor(AssignableMixin, BaseOrgModel):
    name = models.CharField(_("Vendor Name"), max_length=255)
    email = models.EmailField(_("Email"), blank=True, null=True)
    phone = models.CharField(
        _("Phone"),
        max_length=25,
        null=True,
        blank=True,
        validators=[flexible_phone_validator],
    )
    website = models.URLField(_("Website"), blank=True, null=True)

    industry = models.CharField(
        _("Industry"), max_length=255, choices=INDCHOICES, blank=True, null=True
    )
    currency = models.CharField(
        _("Currency"), max_length=3, choices=CURRENCY_CODES, blank=True, null=True
    )

    address_line = models.CharField(_("Address"), max_length=255, blank=True, null=True)
    city = models.CharField(_("City"), max_length=255, blank=True, null=True)
    state = models.CharField(_("State"), max_length=255, blank=True, null=True)
    postcode = models.CharField(_("Postal Code"), max_length=64, blank=True, null=True)
    country = models.CharField(
        _("Country"), max_length=3, choices=COUNTRIES, blank=True, null=True
    )

    assigned_to = models.ManyToManyField(Profile, related_name="vendor_assigned_users")
    teams = models.ManyToManyField(Teams, related_name="vendor_teams")
    contacts = models.ManyToManyField(
        "contacts.Contact", related_name="vendor_contacts"
    )

    tags = models.ManyToManyField(Tags, related_name="vendor_tags", blank=True)

    description = models.TextField(_("Notes"), blank=True, null=True)

    is_active = models.BooleanField(default=True)

    class Meta:
        verbose_name = "Vendor"
        verbose_name_plural = "Vendors"
        db_table = "vendors"
        ordering = ("-created_at",)
        indexes = [
            models.Index(fields=["name"]),
            models.Index(fields=["industry"]),
            models.Index(fields=["org", "-created_at"]),
        ]
        constraints = [
            models.UniqueConstraint(
                Lower("name"),
                "org",
                name="unique_vendor_name_per_org",
            ),
        ]

    def __str__(self):
        return f"{self.name}"


class Bill(BaseOrgModel):
    """A bill a vendor sends us. Attached to a vendor only."""

    STATUS_UNPAID = "UNPAID"
    STATUS_PARTIALLY_PAID = "PARTIALLY_PAID"
    STATUS_PAID = "PAID"
    STATUS_VOID = "VOID"
    STATUS_CHOICES = (
        (STATUS_UNPAID, "Unpaid"),
        (STATUS_PARTIALLY_PAID, "Partly paid"),
        (STATUS_PAID, "Paid"),
        (STATUS_VOID, "Void"),
    )

    vendor = models.ForeignKey(Vendor, on_delete=models.PROTECT, related_name="bills")
    bill_number = models.CharField(_("Bill Number"), max_length=100, blank=True)
    bill_date = models.DateField(_("Bill Date"))
    due_date = models.DateField(_("Due Date"), blank=True, null=True)
    currency = models.CharField(
        _("Currency"), max_length=3, choices=CURRENCY_CODES, blank=True, null=True
    )
    total_amount = models.DecimalField(
        _("Total"), max_digits=12, decimal_places=2, default=0
    )
    amount_paid = models.DecimalField(
        _("Amount Paid"), max_digits=12, decimal_places=2, default=0
    )
    balance_due = models.DecimalField(
        _("Balance Due"), max_digits=12, decimal_places=2, default=0
    )
    status = models.CharField(
        _("Status"), max_length=20, choices=STATUS_CHOICES, default=STATUS_UNPAID
    )
    notes = models.TextField(_("Notes"), blank=True)

    class Meta:
        verbose_name = "Bill"
        verbose_name_plural = "Bills"
        db_table = "vendor_bills"
        ordering = ("-bill_date", "-created_at")
        indexes = [
            models.Index(fields=["org", "status"]),
            models.Index(fields=["org", "due_date"]),
            models.Index(fields=["vendor", "-bill_date"]),
        ]

    def __str__(self):
        return f"{self.vendor} {self.bill_number or self.bill_date}"

    def recalculate(self):
        self.balance_due = max(self.total_amount - self.amount_paid, 0)
        if self.status == self.STATUS_VOID:
            return
        if self.balance_due == 0 and self.total_amount > 0:
            self.status = self.STATUS_PAID
        elif self.amount_paid > 0:
            self.status = self.STATUS_PARTIALLY_PAID
        else:
            self.status = self.STATUS_UNPAID

    def save(self, *args, **kwargs):
        self.recalculate()
        super().save(*args, **kwargs)
