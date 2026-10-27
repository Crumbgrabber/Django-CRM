from uuid import UUID

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from common.models import Org, Teams
from common.tasks import clear_rls_context, set_rls_context

TEAM_NAMES = (
    "Executive",
    "Workflow and Communications",
    "Sales and Marketing",
    "Treasury",
    "Delivery",
    "Qualifications",
    "Public Contact",
)


class Command(BaseCommand):
    help = "Create the seven standard teams for an organization."

    def add_arguments(self, parser):
        parser.add_argument("--org", required=True, help="Organization UUID or name")

    def handle(self, *args, **options):
        value = options["org"]
        try:
            org_id = UUID(value)
        except ValueError:
            lookup = {"name": value}
        else:
            lookup = {"id": org_id}
        try:
            org = Org.objects.get(**lookup)
        except (Org.DoesNotExist, Org.MultipleObjectsReturned) as exc:
            raise CommandError(
                "Choose one existing organization by UUID or unique name."
            ) from exc

        set_rls_context(str(org.id))
        try:
            with transaction.atomic():
                for name in TEAM_NAMES:
                    Teams.objects.get_or_create(
                        org=org, name=name, defaults={"description": ""}
                    )
        finally:
            clear_rls_context()
        self.stdout.write(self.style.SUCCESS("Standard teams are ready."))
