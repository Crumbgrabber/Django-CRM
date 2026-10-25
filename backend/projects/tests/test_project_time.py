"""Tasks and time on projects: the task parent rule, the project time routes,
the rate that fills itself, reports, and the budget notifications."""

import csv
import datetime
import io
from decimal import Decimal

import pytest
from django.utils import timezone

from cases.models import Case, TimeEntry
from common.models import Notification
from common.testing import set_modules_off
from conftest import rls_org
from projects.models import Project, ProjectRate
from projects.tests.conftest import log_time, make_project
from tasks.models import Task

REPORT = "/api/time-entries/report/"
EXPORT = "/api/time-entries/report/export/"


def time_url(project, start=False):
    return f"/api/projects/{project.id}/time-entries/" + ("start/" if start else "")


def _csv(response):
    text = b"".join(response.streaming_content).decode("utf-8-sig")
    return list(csv.reader(io.StringIO(text)))


def manual(**extra):
    end = timezone.now() - datetime.timedelta(hours=1)
    return {
        "started_at": (end - datetime.timedelta(hours=2)).isoformat(),
        "ended_at": end.isoformat(),
        "description": "Design review",
        "billable": True,
        **extra,
    }


@pytest.fixture
def project(org_a, account, admin_user, user_profile):
    return make_project(
        org_a,
        account,
        created_by=admin_user,
        assigned=[user_profile],
        currency="GBP",
        hourly_rate=Decimal("80"),
    )


@pytest.mark.django_db
class TestTaskParent:
    def test_a_task_takes_a_visible_project(self, user_client, project):
        response = user_client.post(
            "/api/tasks/",
            {
                "title": "Wireframes",
                "status": "New",
                "priority": "Low",
                "project": str(project.id),
            },
            format="json",
        )

        assert response.status_code == 200, response.json()
        task = Task.objects.get(title="Wireframes")
        assert task.project_id == project.id
        assert user_client.get(f"/api/tasks/{task.id}/").json()["task_obj"][
            "project"
        ] == str(project.id)

    def test_a_hidden_or_foreign_project_is_refused(
        self, other_member_client, admin_client, project, org_b, org_a
    ):
        with rls_org(org_b):
            from accounts.models import Account

            theirs = make_project(org_b, Account.objects.create(name="B", org=org_b))
        body = {"title": "T", "status": "New", "priority": "Low"}

        hidden = other_member_client.post(
            "/api/tasks/", {**body, "project": str(project.id)}, format="json"
        )
        foreign = admin_client.post(
            "/api/tasks/", {**body, "project": str(theirs.id)}, format="json"
        )

        assert hidden.status_code == 400 and "project" in hidden.json()["errors"]
        assert foreign.status_code == 400 and "project" in foreign.json()["errors"]
        assert not Task.objects.exists()

    def test_one_parent_only(self, admin_client, project, account):
        response = admin_client.post(
            "/api/tasks/",
            {
                "title": "T",
                "status": "New",
                "priority": "Low",
                "project": str(project.id),
                "account": str(account.id),
            },
            format="json",
        )

        assert response.status_code == 400
        assert "Project" in str(response.json()["errors"])

    def test_the_list_filters_by_project(self, admin_client, org_a, project):
        on = Task.objects.create(
            title="On", status="New", priority="Low", org=org_a, project=project
        )
        Task.objects.create(title="Off", status="New", priority="Low", org=org_a)

        rows = admin_client.get("/api/tasks/", {"project": str(project.id)}).json()
        every = admin_client.get("/api/tasks/").json()["tasks"]

        assert [t["id"] for t in rows["tasks"]] == [str(on.id)]
        assert rows["tasks"][0]["project"] == str(project.id)
        assert {t["title"]: t["project"] for t in every} == {
            "On": str(project.id),
            "Off": None,
        }
        board = admin_client.get("/api/tasks/kanban/", {"project": str(project.id)})
        assert board.status_code == 200
        assert str(on.id) in str(board.json())
        assert "Off" not in str(board.json())


@pytest.mark.django_db
class TestProjectTime:
    def test_logging_fills_the_rate_and_the_currency(
        self, user_client, project, user_profile, org_a
    ):
        response = user_client.post(
            time_url(project), manual(currency="USD"), format="json"
        )

        assert response.status_code == 201, response.json()
        body = response.json()
        assert (body["project"], body["project_name"], body["case"]) == (
            str(project.id),
            "Site build",
            None,
        )
        assert (body["hourly_rate"], body["currency"]) == ("80.00", "GBP")

        ProjectRate.objects.create(
            org=org_a, project=project, profile=user_profile, hourly_rate=95
        )
        own = user_client.post(time_url(project), manual(), format="json").json()
        assert own["hourly_rate"] == "95.00"
        typed = user_client.post(
            time_url(project), manual(hourly_rate="10"), format="json"
        ).json()
        assert typed["hourly_rate"] == "95.00"

    def test_no_rate_anywhere_stays_empty(self, admin_client, project):
        Project.objects.filter(pk=project.pk).update(hourly_rate=None)

        body = admin_client.post(time_url(project), manual(), format="json").json()

        assert body["hourly_rate"] is None

    def test_a_task_must_be_on_this_project(
        self, admin_client, project, org_a, account
    ):
        mine = Task.objects.create(
            title="Mine", status="New", priority="Low", org=org_a, project=project
        )
        other = Task.objects.create(
            title="Other", status="New", priority="Low", org=org_a
        )

        refused = admin_client.post(
            time_url(project), manual(task=str(other.id)), format="json"
        )
        malformed = admin_client.post(
            time_url(project), manual(task="x"), format="json"
        )
        allowed = admin_client.post(
            time_url(project), manual(task=str(mine.id)), format="json"
        )

        assert refused.status_code == 400 and "task" in refused.json()
        assert malformed.status_code == 400
        assert allowed.status_code == 201
        assert allowed.json()["task"] == str(mine.id)
        assert TimeEntry.objects.count() == 1

    def test_who_may_log_and_read(
        self, user_client, other_member_client, org_b_client, project, admin_profile
    ):
        log_time(project, admin_profile, 30)

        for client in (other_member_client, org_b_client):
            assert (
                client.post(time_url(project), manual(), format="json").status_code
                == 404
            )
            assert client.get(time_url(project)).status_code == 404
            assert client.post(time_url(project, start=True)).status_code == 404
        assert (
            user_client.post(time_url(project), manual(), format="json").status_code
            == 201
        )
        # A member reads their own time, as on tickets.
        assert len(user_client.get(time_url(project)).json()) == 1

    def test_a_task_the_caller_cannot_open_is_refused(
        self, user_client, org_a, project, admin_user, regular_user
    ):
        hidden = Task.objects.create(
            title="Hidden",
            status="New",
            priority="Low",
            org=org_a,
            project=project,
            created_by=admin_user,
        )
        mine = Task.objects.create(
            title="Mine",
            status="New",
            priority="Low",
            org=org_a,
            project=project,
            created_by=regular_user,
        )

        refused = user_client.post(
            time_url(project), manual(task=str(hidden.id)), format="json"
        )
        timer = user_client.post(
            time_url(project, start=True), {"task": str(hidden.id)}, format="json"
        )
        allowed = user_client.post(
            time_url(project), manual(task=str(mine.id)), format="json"
        )

        assert refused.status_code == 400 and "task" in refused.json()
        assert timer.status_code == 400
        assert allowed.status_code == 201
        entry = TimeEntry.objects.get()
        edit = user_client.put(
            f"/api/time-entries/{entry.id}/", {"task": str(hidden.id)}, format="json"
        )
        assert edit.status_code == 400

    @pytest.mark.parametrize(
        "sent, on_ticket, on_project",
        [
            (None, False, True),
            (True, True, True),
            (False, False, False),
            ("true", True, True),
            ("FALSE", False, False),
        ],
    )
    def test_the_timer_reads_billable_as_a_boolean(
        self, admin_client, org_a, project, sent, on_ticket, on_project
    ):
        case = Case.objects.create(name="T", status="New", priority="Normal", org=org_a)
        body = {} if sent is None else {"billable": sent}
        for url, expected in (
            (time_url(project, start=True), on_project),
            (f"/api/cases/{case.id}/time-entries/start/", on_ticket),
        ):
            response = admin_client.post(url, body, format="json")
            assert response.status_code == 201, response.json()
            assert response.json()["billable"] is expected
            TimeEntry.objects.filter(pk=response.json()["id"]).update(
                ended_at=timezone.now()
            )

    def test_project_time_is_billable_by_default_and_never_on_a_non_billable_one(
        self, admin_client, org_a, project, admin_profile
    ):
        unsent = {k: v for k, v in manual().items() if k != "billable"}
        default = admin_client.post(time_url(project), unsent, format="json")
        declined = admin_client.post(
            time_url(project), manual(billable=False), format="json"
        )
        Project.objects.filter(pk=project.pk).update(billing_type="non_billable")
        forced = admin_client.post(
            time_url(project), manual(billable=True), format="json"
        )
        timer = admin_client.post(time_url(project, start=True), {"billable": True})
        edited = admin_client.put(
            f"/api/time-entries/{default.json()['id']}/",
            {"billable": True, "description": "Still work"},
            format="json",
        )

        assert default.json()["billable"] is True
        assert declined.json()["billable"] is False
        assert forced.json()["billable"] is False
        assert timer.json()["billable"] is False
        assert edited.status_code == 200
        assert edited.json()["billable"] is False

    @pytest.mark.parametrize("sent", ["yes", "0", 1, "nope", ["true"]])
    def test_the_timer_refuses_anything_else(self, admin_client, org_a, project, sent):
        case = Case.objects.create(name="T", status="New", priority="Normal", org=org_a)
        for url in (
            time_url(project, start=True),
            f"/api/cases/{case.id}/time-entries/start/",
        ):
            response = admin_client.post(url, {"billable": sent}, format="json")
            assert response.status_code == 400
            assert "billable" in response.json()
        assert not TimeEntry.objects.exists()

    def test_the_timer_starts_once(self, user_client, project):
        first = user_client.post(time_url(project, start=True), {"description": "Go"})
        second = user_client.post(time_url(project, start=True))

        assert first.status_code == 201
        assert (first.json()["hourly_rate"], first.json()["currency"]) == (
            "80.00",
            "GBP",
        )
        assert second.status_code == 409
        assert second.json()["running_project_id"] == str(project.id)
        assert second.json()["running_case_id"] is None

    def test_the_ticket_timer_409_names_a_running_project_timer(
        self, admin_client, org_a, project
    ):
        case = Case.objects.create(name="T", status="New", priority="Normal", org=org_a)
        ticket_start = f"/api/cases/{case.id}/time-entries/start/"
        running = admin_client.post(time_url(project, start=True)).json()

        on_ticket = admin_client.post(ticket_start)
        TimeEntry.objects.filter(pk=running["id"]).update(ended_at=timezone.now())
        admin_client.post(ticket_start)
        on_project = admin_client.post(time_url(project, start=True))

        assert on_ticket.status_code == 409
        assert on_ticket.json()["running_case_id"] is None
        assert on_ticket.json()["running_project_id"] == str(project.id)
        assert on_project.status_code == 409
        assert on_project.json()["running_case_id"] == str(case.id)
        assert on_project.json()["running_project_id"] is None

    def test_stop_and_edit_stay_on_the_entry_routes(
        self, user_client, project, org_a, regular_user
    ):
        started = user_client.post(time_url(project, start=True)).json()
        task = Task.objects.create(
            title="T",
            status="New",
            priority="Low",
            org=org_a,
            project=project,
            created_by=regular_user,
        )

        stopped = user_client.post(f"/api/time-entries/{started['id']}/stop/")
        edited = user_client.put(
            f"/api/time-entries/{started['id']}/",
            {"description": "Edited", "task": str(task.id), "currency": "USD"},
            format="json",
        )

        assert stopped.status_code == 200
        assert edited.status_code == 200
        assert (edited.json()["task"], edited.json()["currency"]) == (
            str(task.id),
            "GBP",
        )

    def test_a_ticket_entry_cannot_name_a_task(
        self, admin_client, org_a, admin_user, admin_profile
    ):
        case = Case.objects.create(name="T", status="New", priority="Normal", org=org_a)
        entry = TimeEntry.objects.create(
            org=org_a,
            case=case,
            profile=admin_profile,
            started_at=timezone.now() - datetime.timedelta(hours=1),
            ended_at=timezone.now(),
        )
        task = Task.objects.create(title="T", status="New", priority="Low", org=org_a)

        response = admin_client.put(
            f"/api/time-entries/{entry.id}/", {"task": str(task.id)}, format="json"
        )

        assert response.status_code == 400

    def test_the_database_refuses_both_parents(self, org_a, project, admin_profile):
        from django.db import IntegrityError, transaction

        case = Case.objects.create(name="T", status="New", priority="Normal", org=org_a)
        with pytest.raises(IntegrityError), transaction.atomic():
            TimeEntry.objects.create(
                org=org_a,
                case=case,
                project=project,
                profile=admin_profile,
                started_at=timezone.now(),
            )


@pytest.mark.django_db
class TestReports:
    def test_group_by_project_and_billable_share(
        self, admin_client, org_a, project, admin_profile, user_profile
    ):
        log_time(project, admin_profile, 90)
        log_time(project, admin_profile, 30, billable=False)
        case = Case.objects.create(name="T", status="New", priority="Normal", org=org_a)
        TimeEntry.objects.create(
            org=org_a,
            case=case,
            profile=user_profile,
            started_at=timezone.now() - datetime.timedelta(hours=1),
            ended_at=timezone.now(),
        )

        by_project = admin_client.get(REPORT, {"group_by": "project"}).json()
        by_agent = admin_client.get(REPORT, {"group_by": "agent"}).json()

        names = {r["name"]: r for r in by_project["rows"]}
        assert names["Site build"]["total_minutes"] == 120
        assert names["Site build"]["billable_minutes"] == 90
        assert names["No project"]["total_minutes"] == 60
        shares = {r["key"]: r["billable_share"] for r in by_agent["rows"]}
        assert shares == {str(admin_profile.id): 0.75, str(user_profile.id): 0.0}
        assert "billable_share" not in by_project["rows"][0]

    def test_a_project_entrys_account_is_the_projects(
        self, admin_client, project, account, admin_profile
    ):
        log_time(project, admin_profile, 60)

        rows = admin_client.get(REPORT, {"group_by": "account"}).json()["rows"]
        filtered = admin_client.get(REPORT, {"account": str(account.id)}).json()

        assert [(r["key"], r["name"]) for r in rows] == [
            (str(account.id), "Reyes & Co")
        ]
        assert filtered["totals"]["total_minutes"] == 60

    def test_the_project_filter(
        self, admin_client, org_a, project, account, admin_profile
    ):
        other = make_project(org_a, account, name="Other")
        log_time(project, admin_profile, 60)
        log_time(other, admin_profile, 15)

        body = admin_client.get(REPORT, {"project": str(project.id)}).json()

        assert body["totals"]["total_minutes"] == 60
        assert admin_client.get(REPORT, {"project": "x"}).status_code == 400

    def test_the_csv_has_a_project_column(self, admin_client, project, admin_profile):
        log_time(project, admin_profile, 60, description="Sketches")

        rows = _csv(admin_client.get(EXPORT))

        assert rows[0][2:5] == ["Ticket", "Project", "Account"]
        assert rows[1][2:6] == ["", "Site build", "Reyes & Co", "Sketches"]


@pytest.mark.django_db
class TestAnEntryWithNoParent:
    """A deleted project leaves its entries with neither a ticket nor a
    project. Every reader takes them without a 500."""

    @pytest.fixture
    def orphan(self, project, admin_profile):
        entry = log_time(project, admin_profile, 45, description="Orphaned")
        project.delete()
        entry.refresh_from_db()
        assert (entry.case_id, entry.project_id) == (None, None)
        return entry

    def test_the_timesheet(self, admin_client, orphan):
        day = timezone.localdate(orphan.started_at).isoformat()
        body = admin_client.get(
            "/api/time-entries/timesheet/", {"start": day, "end": day}
        ).json()

        entry = body["days"][0]["entries"][0]
        assert (entry["case"], entry["project"], entry["project_name"]) == (
            None,
            None,
            None,
        )

    @pytest.mark.parametrize("group_by", ["agent", "ticket", "project", "account"])
    def test_every_report_grouping(self, admin_client, orphan, group_by):
        body = admin_client.get(REPORT, {"group_by": group_by}).json()

        assert body["totals"]["total_minutes"] == 45
        if group_by != "agent":
            assert body["rows"][0]["key"] is None
            assert body["rows"][0]["name"] in ("No ticket", "No project", "No account")

    def test_the_csv(self, admin_client, orphan):
        rows = _csv(admin_client.get(EXPORT))

        assert rows[1][2:6] == ["", "", "", "Orphaned"]

    def test_the_unbilled_list(self, admin_client, orphan):
        response = admin_client.get("/api/time-entries/unbilled/")

        assert response.status_code == 200
        assert [e["id"] for e in response.json()] == [str(orphan.id)]

    def test_edit_stop_and_delete(self, admin_client, orphan):
        url = f"/api/time-entries/{orphan.id}/"
        assert (
            admin_client.put(url, {"description": "Kept"}, format="json").status_code
            == 200
        )
        assert admin_client.post(f"{url}stop/").status_code == 400
        assert admin_client.delete(url).status_code == 204


@pytest.mark.django_db
class TestBudgetNotifications:
    def _notes(self):
        return list(
            Notification.objects.filter(verb="project.budget")
            .order_by("recipient__user__email", "created_at")
            .values_list("recipient_id", "data")
        )

    def test_80_then_100_once_each_to_people_and_admins(
        self, user_client, org_a, project, admin_profile, user_profile, other_member
    ):
        Project.objects.filter(pk=project.pk).update(budget_hours=Decimal("10"))

        def log(hours):
            end = timezone.now() - datetime.timedelta(hours=1)
            start = end - datetime.timedelta(hours=hours)
            return user_client.post(
                time_url(project),
                manual(started_at=start.isoformat(), ended_at=end.isoformat()),
                format="json",
            )

        log(7)
        assert self._notes() == []
        log(1)
        eighty = {"kind": "hours", "percent": 80, "project": "Site build"}
        assert sorted(self._notes(), key=str) == sorted(
            [(admin_profile.id, eighty), (user_profile.id, eighty)], key=str
        )
        log(1)
        assert len(self._notes()) == 2
        log(2)
        hundred = {"kind": "hours", "percent": 100, "project": "Site build"}
        assert [d for _, d in self._notes()].count(hundred) == 2
        log(5)
        assert len(self._notes()) == 4
        note = Notification.objects.filter(recipient=user_profile).first()
        assert note.link == f"/projects/{project.id}"
        assert not Notification.objects.filter(recipient=other_member).exists()
        project.refresh_from_db()
        assert project.hours_alert == 100

    def test_an_edit_that_crosses_the_amount_budget_notifies(
        self, admin_client, project, admin_profile
    ):
        Project.objects.filter(pk=project.pk).update(budget_amount=Decimal("100"))
        entry = log_time(project, admin_profile, 30, rate="100")  # 50.00
        end = entry.ended_at
        response = admin_client.put(
            f"/api/time-entries/{entry.id}/",
            {"started_at": (end - datetime.timedelta(minutes=60)).isoformat()},
            format="json",
        )

        assert response.status_code == 200
        data = [d for _, d in self._notes()]
        assert data == [{"kind": "amount", "percent": 100, "project": "Site build"}] * 2

    def test_a_stopped_timer_is_checked_too(self, admin_client, project, admin_profile):
        Project.objects.filter(pk=project.pk).update(budget_hours=Decimal("1"))
        entry = TimeEntry.objects.create(
            org=project.org,
            project=project,
            profile=admin_profile,
            started_at=timezone.now() - datetime.timedelta(minutes=50),
            currency="GBP",
        )

        admin_client.post(f"/api/time-entries/{entry.id}/stop/")

        assert [d["percent"] for _, d in self._notes()] == [80, 80]

    def test_an_auto_stopped_timer_is_checked_too(self, org_a, project, admin_profile):
        from cases.tasks import auto_stop_stale_timers

        Project.objects.filter(pk=project.pk).update(budget_hours=Decimal("10"))
        TimeEntry.objects.create(
            org=org_a,
            project=project,
            profile=admin_profile,
            started_at=timezone.now() - datetime.timedelta(hours=13),
            currency="GBP",
        )

        assert auto_stop_stale_timers() == 1

        assert [d["percent"] for _, d in self._notes()] == [100, 100]

    def test_nothing_while_projects_is_off(
        self, admin_client, org_a, project, admin_profile
    ):
        Project.objects.filter(pk=project.pk).update(budget_hours=Decimal("1"))
        entry = TimeEntry.objects.create(
            org=org_a,
            project=project,
            profile=admin_profile,
            started_at=timezone.now() - datetime.timedelta(hours=2),
            currency="GBP",
        )
        set_modules_off(org_a, "projects")

        assert (
            admin_client.post(f"/api/time-entries/{entry.id}/stop/").status_code == 200
        )
        assert self._notes() == []
