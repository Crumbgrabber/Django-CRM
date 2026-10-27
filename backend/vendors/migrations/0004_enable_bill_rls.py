from django.db import connection, migrations

from common.rls import get_disable_policy_sql, get_enable_policy_sql

TABLE = "vendor_bills"


def enable_rls(apps, schema_editor):
    if connection.vendor == "postgresql":
        with connection.cursor() as cursor:
            cursor.execute(get_enable_policy_sql(TABLE))


def disable_rls(apps, schema_editor):
    if connection.vendor == "postgresql":
        with connection.cursor() as cursor:
            cursor.execute(get_disable_policy_sql(TABLE))


class Migration(migrations.Migration):
    atomic = False
    dependencies = [("vendors", "0003_bill")]
    operations = [migrations.RunPython(enable_rls, disable_rls)]
