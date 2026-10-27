from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("common", "0062_backfill_installed_apps")]

    operations = [
        migrations.AlterField(
            model_name="teams", name="description", field=models.TextField(blank=True)
        ),
    ]
