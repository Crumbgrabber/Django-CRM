"""The Professional Services app's version 3: a new install with sample data
gets a sample project with time and a task on it; an update never adds it, and
clearing sample data removes only the sample rows."""

import copy
import datetime
from decimal import Decimal
from unittest import mock

import pytest
from django.utils import timezone

from accounts.models import Account
from cases.models import TimeEntry
from common.apps_catalogue import install_app, upgrade_app
from common.models import Tags
from common.packs.applier import apply_pack, clear_sample_data
from common.packs.loader import get_pack, get_registry
from common.packs.planner import plan_app
from common.packs.schema import PackValidationError, validate_manifest
from common.testing import set_modules_off
from invoices.models import Invoice
from projects.burn import burn_for
from projects.models import Project
from tasks.models import Task

APP = "professional-services"
PROJECT = "Meridian audit fieldwork"


def _skipped(report, type_):
    return [s for s in report["skipped"] if s["type"] == type_]


def _created(report, type_):
    return [c for c in report["created"] if c["type"] == type_]


def test_the_manifest_is_version_3_with_a_sample_project():
    pack = get_pack(APP)
    assert pack["version"] == 3
    assert [p["name"] for p in pack["sample_data"]["projects"]] == [PROJECT]
    assert 2 <= len(pack["sample_data"]["time_entries"]) <= 3


def test_a_new_install_creates_the_sample_project(org_a, admin_profile):
    install_app(org_a, APP, admin_profile, sample_data=True)

    project = Project.objects.get(org=org_a)
    assert project.is_sample and project.name == PROJECT
    assert project.account.is_sample
    assert project.account.name == "Meridian Health Partners"
    assert project.deal.is_sample and project.deal.name == "Meridian audit support"
    assert project.billing_type == "time_and_materials"
    assert (project.hourly_rate, project.budget_hours, project.budget_amount) == (
        Decimal("150.00"),
        Decimal("60.00"),
        Decimal("9000.00"),
    )
    assert project.start_date == timezone.localdate() - datetime.timedelta(days=14)
    assert project.created_by == admin_profile.user
    assert list(project.assigned_to.all()) == [admin_profile]
    assert project.tags.filter(slug="sample-data").exists()

    entries = TimeEntry.objects.filter(org=org_a).order_by("started_at")
    assert entries.count() == 3
    for entry in entries:
        assert entry.is_sample and entry.project == project and entry.case is None
        assert entry.profile == admin_profile
        assert entry.billable and entry.ended_at is not None
        assert (entry.hourly_rate, entry.currency) == (Decimal("150.00"), "USD")
    assert [e.duration_minutes for e in entries] == [180, 270, 120]
    assert entries[0].started_at.date() <= timezone.localdate()

    task = Task.objects.get(org=org_a, project=project)
    assert task.is_sample and task.stage.name == "In progress"


def test_the_sample_project_burns(org_a, admin_profile):
    apply_pack(org_a, get_pack(APP), admin_profile)
    project = Project.objects.get(org=org_a, is_sample=True)
    burn = burn_for([project], admin_profile)[project.pk]
    assert burn["logged_hours"] == "9.50"
    assert burn["billable_value"] == "1425.00"
    assert burn["unbilled_value"] == "1425.00"
    assert (burn["hours_percent"], burn["amount_percent"]) == (15, 15)


def test_the_report_counts_them(org_a, admin_profile):
    report = apply_pack(org_a, get_pack(APP), admin_profile)
    assert len(_created(report, "sample_project")) == 1
    assert len(_created(report, "sample_time_entry")) == 3
    preview_records = 0
    for section in get_pack(APP)["sample_data"].values():
        preview_records += len(section)
    clear_sample_data(org_a, admin_profile)
    assert plan_app(org_a, APP, "install")["sample_data"]["records"] == (
        preview_records
    )


@pytest.fixture
def catalogue():
    registry = get_registry()
    with mock.patch.dict(registry):
        yield registry


def _version_2():
    pack = copy.deepcopy(get_pack(APP))
    pack["version"] = 2
    sample = pack["sample_data"]
    del sample["projects"], sample["time_entries"]
    sample["tasks"] = [t for t in sample["tasks"] if not t.get("project")]
    pack["tags"] = [t for t in pack["tags"] if t["name"] != "Rebid"]
    return validate_manifest(pack)


def test_an_update_never_adds_the_sample_project(org_a, admin_profile, catalogue):
    current = catalogue[APP]
    catalogue[APP] = _version_2()
    install_app(org_a, APP, admin_profile, sample_data=True)
    assert Account.objects.filter(org=org_a, is_sample=True).exists()
    catalogue[APP] = current

    assert plan_app(org_a, APP, "upgrade")["sample_data"]["offered"] is False
    row = upgrade_app(org_a, APP, admin_profile)

    assert row.installed_version == 3
    assert Tags.objects.filter(org=org_a, slug="rebid").exists()
    assert not Project.objects.filter(org=org_a).exists()
    assert not TimeEntry.objects.filter(org=org_a).exists()
    assert not Task.objects.filter(org=org_a, project__isnull=False).exists()


class TestClear:
    def test_clearing_removes_only_sample_rows(self, org_a, admin_profile):
        apply_pack(org_a, get_pack(APP), admin_profile)
        sample = Project.objects.get(org=org_a, is_sample=True)
        real_account = Account.objects.create(org=org_a, name="A real client")
        real = Project.objects.create(org=org_a, name="Real", account=real_account)
        now = timezone.now()
        on_sample = TimeEntry.objects.create(
            org=org_a,
            project=sample,
            profile=admin_profile,
            started_at=now - datetime.timedelta(hours=1),
            ended_at=now,
        )
        on_real = TimeEntry.objects.create(
            org=org_a,
            project=real,
            profile=admin_profile,
            started_at=now - datetime.timedelta(hours=3),
            ended_at=now - datetime.timedelta(hours=2),
        )

        result = clear_sample_data(org_a, admin_profile)

        assert result["deleted"]["sample_project"] == 1
        assert result["deleted"]["sample_time_entry"] == 3
        assert "sample_project" not in result["retained"]
        assert not Project.objects.filter(is_sample=True).exists()
        assert not TimeEntry.objects.filter(is_sample=True).exists()
        assert not Task.objects.filter(is_sample=True).exists()
        assert not Account.objects.filter(is_sample=True).exists()
        on_sample.refresh_from_db()
        on_real.refresh_from_db()
        assert on_sample.project is None
        assert on_real.project == real
        assert Project.objects.get() == real

    def test_kept_sample_time_keeps_its_project(self, org_a, admin_profile):
        apply_pack(org_a, get_pack(APP), admin_profile)
        set_modules_off(org_a, "timesheet")

        result = clear_sample_data(org_a, admin_profile)

        assert result["switched_off"] == {"sample_time_entry": 3}
        assert result["retained"]["sample_project"] == 1
        assert "sample_project" not in result["deleted"]
        project = Project.objects.get(is_sample=True)
        assert TimeEntry.objects.filter(is_sample=True, project=project).count() == 3
        assert project.account.is_sample
        assert not Task.objects.filter(is_sample=True).exists()

        # With the module back on, the next clear takes the lot, and nothing
        # left behind stops the app installing its sample data again.
        set_modules_off(org_a)
        result = clear_sample_data(org_a, admin_profile)
        assert result["deleted"]["sample_time_entry"] == 3
        assert result["deleted"]["sample_project"] == 1
        assert not TimeEntry.objects.exists() and not Project.objects.exists()
        report = apply_pack(org_a, get_pack(APP), admin_profile)
        assert not _skipped(report, "sample_data")
        assert len(_created(report, "sample_project")) == 1
        assert TimeEntry.objects.filter(is_sample=True).count() == 3

    def test_billed_sample_time_is_kept(self, org_a, admin_profile):
        apply_pack(org_a, get_pack(APP), admin_profile)
        project = Project.objects.get(is_sample=True)
        billed, *unbilled = TimeEntry.objects.filter(is_sample=True).order_by(
            "started_at"
        )
        invoice = Invoice.objects.create(
            org=org_a, account=project.account, project=project, invoice_title="Time"
        )
        TimeEntry.objects.filter(pk=billed.pk).update(invoice=invoice)

        result = clear_sample_data(org_a, admin_profile)

        assert result["retained"]["sample_time_entry"] == 1
        assert result["deleted"]["sample_time_entry"] == 2
        assert result["retained"]["sample_project"] == 1
        billed.refresh_from_db()
        assert (billed.invoice, billed.project) == (invoice, project)
        assert not TimeEntry.objects.filter(pk__in=[e.pk for e in unbilled]).exists()

        # Cancelling the invoice frees the time, and the next clear leaves no
        # sample time or project behind.
        invoice.status = "Cancelled"
        invoice.save()
        result = clear_sample_data(org_a, admin_profile)
        assert result["deleted"]["sample_time_entry"] == 1
        assert result["deleted"]["sample_project"] == 1
        assert not TimeEntry.objects.exists() and not Project.objects.exists()

    def test_a_sample_project_counts_as_sample_data_present(self, org_a, admin_profile):
        account = Account.objects.create(org=org_a, name="A real client")
        Project.objects.create(org=org_a, name="Demo", account=account, is_sample=True)

        report = apply_pack(org_a, get_pack(APP), admin_profile)

        assert _skipped(report, "sample_data") == [
            {"type": "sample_data", "name": APP, "reason": "already exists"}
        ]
        assert not Account.objects.filter(is_sample=True).exists()
        assert plan_app(org_a, APP, "install")["sample_data"]["offered"] is False

    def test_sample_time_alone_counts_too(self, org_a, admin_profile):
        account = Account.objects.create(org=org_a, name="A real client")
        project = Project.objects.create(org=org_a, name="Real", account=account)
        now = timezone.now()
        TimeEntry.objects.create(
            org=org_a,
            project=project,
            profile=admin_profile,
            started_at=now,
            ended_at=now,
            is_sample=True,
        )
        report = apply_pack(org_a, get_pack(APP), admin_profile)
        assert _skipped(report, "sample_data")


class TestSkips:
    def test_projects_off_skips_the_project_its_task_and_its_time(
        self, org_a, admin_profile
    ):
        set_modules_off(org_a, "projects")
        report = apply_pack(org_a, get_pack(APP), admin_profile)
        assert not Project.objects.exists() and not TimeEntry.objects.exists()
        assert _skipped(report, "sample_project")[0]["reason"] == (
            "Projects is switched off for this organization."
        )
        assert len(_skipped(report, "sample_time_entry")) == 3
        assert [s["name"] for s in _skipped(report, "sample_task")] == [
            "Test the Q1 purchase ledger sample"
        ]
        assert Account.objects.filter(is_sample=True).exists()

    def test_timesheet_off_skips_only_the_time(self, org_a, admin_profile):
        set_modules_off(org_a, "timesheet")
        report = apply_pack(org_a, get_pack(APP), admin_profile)
        assert Project.objects.filter(is_sample=True).count() == 1
        assert not TimeEntry.objects.exists()
        assert len(_skipped(report, "sample_time_entry")) == 3

    def test_no_actor_logs_no_time(self, org_a):
        report = apply_pack(org_a, get_pack(APP), None)
        project = Project.objects.get(is_sample=True)
        assert not project.assigned_to.exists()
        assert not TimeEntry.objects.exists()
        assert {s["reason"] for s in _skipped(report, "sample_time_entry")} == {
            "there is no one to log it for"
        }

    def test_a_real_account_of_the_same_name_skips_the_project(
        self, org_a, admin_profile
    ):
        Account.objects.create(org=org_a, name="Meridian Health Partners")
        report = apply_pack(org_a, get_pack(APP), admin_profile)
        assert not Project.objects.exists()
        assert _skipped(report, "sample_project")[0]["reason"] == (
            "its sample account is missing"
        )


def _manifest_with(**sample_changes):
    pack = copy.deepcopy(copy.deepcopy(get_pack(APP)))
    pack["sample_data"].update(sample_changes)
    return pack


class TestSchema:
    @pytest.mark.parametrize(
        "entries, message",
        [
            ([{"project": "Nope", "date": "2026-08-01", "hours": 1}], "does not match"),
            ([{"project": PROJECT, "date": "2026-08-01", "hours": 0}], "required"),
            ([{"project": PROJECT, "date": "2026-08-01", "hours": 25}], "at most 24"),
            ([{"project": PROJECT, "date": "2026-08-01", "hours": "x"}], "number"),
            ([{"project": PROJECT, "date": "soon", "hours": 1}], "ISO date"),
            (
                [{"project": PROJECT, "date": "2026-08-01", "hours": 1, "rate": 9}],
                "unknown",
            ),
        ],
    )
    def test_bad_time_entries(self, entries, message):
        with pytest.raises(PackValidationError, match=message):
            validate_manifest(_manifest_with(time_entries=entries))

    @pytest.mark.parametrize(
        "change, message",
        [
            ({"billing_type": "retainer"}, "billing_type"),
            ({"hourly_rate": -1}, "0 or more"),
            ({"account": "Nobody"}, "does not match"),
            ({"deal": "Nothing"}, "does not match"),
            ({"currency": "XXX"}, "currency"),
        ],
    )
    def test_bad_projects(self, change, message):
        project = {
            **copy.deepcopy(get_pack(APP))["sample_data"]["projects"][0],
            **change,
        }
        with pytest.raises(PackValidationError, match=message):
            validate_manifest(_manifest_with(projects=[project]))

    def test_a_task_on_a_project_and_a_deal(self):
        pack = copy.deepcopy(get_pack(APP))
        tasks = pack["sample_data"]["tasks"]
        tasks[-1] = {**tasks[-1], "deal": "Meridian audit support"}
        with pytest.raises(PackValidationError, match="at most one parent"):
            validate_manifest(_manifest_with(tasks=tasks))
