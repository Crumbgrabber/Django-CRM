from django.db import connection, migrations

from common.rls import get_disable_policy_sql, get_enable_policy_sql

TABLES = ("project", "project_rate")


def enable_rls(apps, schema_editor):
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        for table in TABLES:
            cursor.execute(get_enable_policy_sql(table))


def disable_rls(apps, schema_editor):
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        for table in TABLES:
            cursor.execute(get_disable_policy_sql(table))


class Migration(migrations.Migration):
    atomic = False

    dependencies = [
        ("projects", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(enable_rls, disable_rls),
    ]
