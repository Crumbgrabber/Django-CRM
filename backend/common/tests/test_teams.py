"""
Tests for team management views: list, create, detail, update, delete teams.

Run with: pytest common/tests/test_teams.py -v
"""

import pytest
from rest_framework import status

from common.models import Teams


@pytest.mark.django_db
class TestTeamsListView:
    """Tests for GET/POST /api/teams/"""

    url = "/api/teams/"

    def test_create_team(self, admin_client, org_a):
        response = admin_client.post(
            self.url,
            {"name": "Engineering", "description": "Engineering team"},
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False

    def test_list_teams(self, admin_client, org_a):
        Teams.objects.create(name="Sales", org=org_a)
        response = admin_client.get(self.url)
        assert response.status_code == status.HTTP_200_OK
        assert "teams" in response.data

    def test_list_teams_non_admin(self, user_client):
        response = user_client.get(self.url)
        assert response.status_code == status.HTTP_403_FORBIDDEN

    def test_create_team_non_admin_forbidden(self, user_client):
        """Non-admin user cannot create teams."""
        response = user_client.post(
            self.url,
            {"name": "No Permission Team", "description": "Nope"},
            format="json",
        )
        assert response.status_code == status.HTTP_403_FORBIDDEN

    def test_create_team_duplicate_name(self, admin_client, org_a):
        """Creating a team with a duplicate name should fail."""
        Teams.objects.create(name="Duplicate Team", org=org_a)
        response = admin_client.post(
            self.url,
            {"name": "Duplicate Team", "description": "Duplicate"},
            format="json",
        )
        assert response.status_code == status.HTTP_400_BAD_REQUEST

    def test_create_team_with_users(self, admin_client, org_a, admin_profile):
        """Create a team and assign users."""
        response = admin_client.post(
            self.url,
            {
                "name": "User Team",
                "description": "Team with users",
                "assign_users": [str(admin_profile.id)],
            },
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False

    def test_list_teams_context_keys(self, admin_client, org_a):
        """Team list should include expected context keys."""
        Teams.objects.create(name="Context Team", org=org_a)
        response = admin_client.get(self.url)
        assert response.status_code == status.HTTP_200_OK
        assert "teams" in response.data
        assert "teams_count" in response.data
        assert "per_page" in response.data

    def test_list_teams_filter_by_name(self, admin_client, org_a):
        """Filter teams by team_name parameter."""
        Teams.objects.create(name="Alpha Team", org=org_a)
        Teams.objects.create(name="Beta Team", org=org_a)
        response = admin_client.get(self.url + "?team_name=Alpha")
        assert response.status_code == status.HTTP_200_OK
        assert response.data["teams_count"] == 1


@pytest.mark.django_db
class TestTeamsDetailView:
    """Tests for GET/PUT/PATCH/DELETE /api/teams/<pk>/"""

    def _url(self, pk):
        return f"/api/teams/{pk}/"

    def test_get_team_detail(self, admin_client, org_a):
        team = Teams.objects.create(name="Support", org=org_a)
        response = admin_client.get(self._url(team.pk))
        assert response.status_code == status.HTTP_200_OK
        assert "team" in response.data

    def test_update_team(self, admin_client, org_a):
        team = Teams.objects.create(name="Old Name", org=org_a)
        response = admin_client.put(
            self._url(team.pk),
            {"name": "New Name", "description": "Updated"},
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False

    def test_delete_team(self, admin_client, org_a):
        team = Teams.objects.create(name="To Delete", org=org_a)
        response = admin_client.delete(self._url(team.pk))
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False
        assert not Teams.objects.filter(pk=team.pk).exists()

    def test_get_team_non_admin_forbidden(self, user_client, org_a):
        """Non-admin cannot view team details."""
        team = Teams.objects.create(name="No View", org=org_a)
        response = user_client.get(self._url(team.pk))
        assert response.status_code == status.HTTP_403_FORBIDDEN

    def test_update_team_non_admin_forbidden(self, user_client, org_a):
        """Non-admin cannot update teams."""
        team = Teams.objects.create(name="No Update", org=org_a)
        response = user_client.put(
            self._url(team.pk),
            {"name": "Not Allowed", "description": "Nope"},
            format="json",
        )
        assert response.status_code == status.HTTP_403_FORBIDDEN

    def test_delete_team_non_admin_forbidden(self, user_client, org_a):
        """Non-admin cannot delete teams."""
        team = Teams.objects.create(name="No Delete", org=org_a)
        response = user_client.delete(self._url(team.pk))
        assert response.status_code == status.HTTP_403_FORBIDDEN

    def test_update_team_with_users(self, admin_client, org_a, admin_profile):
        """Update team with assigned users."""
        team = Teams.objects.create(name="Assign Team", org=org_a)
        response = admin_client.put(
            self._url(team.pk),
            {
                "name": "Assign Team",
                "description": "With users",
                "assign_users": [str(admin_profile.id)],
            },
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False

    def test_update_team_duplicate_name(self, admin_client, org_a):
        """Updating to a duplicate name should fail."""
        Teams.objects.create(name="Existing Team", org=org_a)
        team = Teams.objects.create(name="Rename Me", org=org_a)
        response = admin_client.put(
            self._url(team.pk),
            {"name": "Existing Team", "description": "dup"},
            format="json",
        )
        assert response.status_code == status.HTTP_400_BAD_REQUEST

    def test_patch_team(self, admin_client, org_a):
        """Test partial update via PATCH."""
        team = Teams.objects.create(name="Patch Team", org=org_a)
        response = admin_client.patch(
            self._url(team.pk),
            {"description": "Patched description"},
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK
        assert response.data["error"] is False

    def test_patch_team_non_admin_forbidden(self, user_client, org_a):
        """Non-admin cannot PATCH teams."""
        team = Teams.objects.create(name="No Patch", org=org_a)
        response = user_client.patch(
            self._url(team.pk),
            {"description": "Nope"},
            format="json",
        )
        assert response.status_code == status.HTTP_403_FORBIDDEN


@pytest.mark.django_db
class TestTeamMembership:
    @pytest.mark.parametrize("method", ["post", "put"])
    def test_assign_admin_and_member(
        self, method, admin_client, org_a, admin_profile, user_profile
    ):
        team = Teams.objects.create(name="Membership", org=org_a)
        url = "/api/teams/" if method == "post" else f"/api/teams/{team.pk}/"
        name = "New membership" if method == "post" else team.name
        response = getattr(admin_client, method)(
            url,
            {
                "name": name,
                "description": "",
                "assign_users": [str(admin_profile.pk), str(user_profile.pk)],
            },
            format="json",
        )
        assert response.status_code == 200
        assert set(Teams.objects.get(org=org_a, name=name).users.all()) == {
            admin_profile,
            user_profile,
        }

    def test_clear_members_keeps_accounts_active(
        self, admin_client, org_a, admin_profile, user_profile
    ):
        team = Teams.objects.create(name="Clear", org=org_a)
        other = Teams.objects.create(name="Other", org=org_a)
        team.users.set([admin_profile, user_profile])
        other.users.add(user_profile)
        response = admin_client.put(
            f"/api/teams/{team.pk}/",
            {"name": team.name, "assign_users": []},
            format="json",
        )
        assert response.status_code == 200
        assert not team.users.exists()
        assert other.users.filter(pk=user_profile.pk).exists()
        for profile in (admin_profile, user_profile):
            profile.refresh_from_db()
            assert profile.is_active
            profile.user.refresh_from_db()
            assert profile.user.is_active

    @pytest.mark.parametrize("method", ["post", "put"])
    @pytest.mark.parametrize(
        "invalid", ["foreign", "inactive", "malformed", "missing", "flag"]
    )
    def test_invalid_members_rejected_before_write(
        self, method, invalid, admin_client, org_a, profile_b, user_profile
    ):
        from uuid import uuid4

        team = Teams.objects.create(name="Unchanged", org=org_a)
        team.users.add(user_profile)
        user_profile.is_active = False
        user_profile.save()
        values = {
            "foreign": [str(profile_b.pk)],
            "inactive": [str(user_profile.pk)],
            "malformed": ["not-an-id"],
            "missing": [str(uuid4())],
            "flag": True,
        }
        url = "/api/teams/" if method == "post" else f"/api/teams/{team.pk}/"
        response = getattr(admin_client, method)(
            url, {"name": "Changed", "assign_users": values[invalid]}, format="json"
        )
        assert response.status_code == 400
        team.refresh_from_db()
        assert team.name == "Unchanged"
        assert list(team.users.all()) == [user_profile]
        assert not Teams.objects.filter(org=org_a, name="Changed").exists()

    @pytest.mark.parametrize("method", ["put", "delete"])
    def test_foreign_team_inaccessible(self, method, admin_client, org_b):
        team = Teams.objects.create(name="Foreign", org=org_b)
        response = getattr(admin_client, method)(
            f"/api/teams/{team.pk}/",
            {"name": "Changed", "assign_users": []},
            format="json",
        )
        assert response.status_code == 404
        assert Teams.objects.filter(pk=team.pk, org=org_b).exists()

    def test_delete_preserves_members(self, admin_client, org_a, user_profile):
        team = Teams.objects.create(name="Delete members", org=org_a)
        team.users.add(user_profile)
        assert admin_client.delete(f"/api/teams/{team.pk}/").status_code == 200
        user_profile.refresh_from_db()
        assert user_profile.is_active


@pytest.mark.django_db
@pytest.mark.parametrize("by_id", [True, False])
def test_seed_teams_idempotent(org_a, org_b, by_id):
    from django.core.management import call_command

    from common.management.commands.seed_teams import TEAM_NAMES

    value = str(org_a.pk) if by_id else org_a.name
    call_command("seed_teams", org=value)
    call_command("seed_teams", org=value)
    teams = Teams.objects.filter(org=org_a)
    assert teams.count() == 7
    assert set(teams.values_list("name", flat=True)) == set(TEAM_NAMES)
    assert all(team.description == "" and not team.users.exists() for team in teams)
    assert not Teams.objects.filter(org=org_b).exists()


@pytest.mark.django_db
@pytest.mark.parametrize("has_context", [True, False])
def test_team_requires_org_context(admin_user, admin_profile, org_a, has_context):
    from rest_framework.test import APIRequestFactory, force_authenticate

    from common.views.team_views import TeamsListView

    request = APIRequestFactory().post(
        "/api/teams/", {"name": "Empty", "assign_users": []}, format="json"
    )
    force_authenticate(request, user=admin_user)
    request.profile = admin_profile if has_context else None
    request.org = org_a if has_context else None
    response = TeamsListView.as_view()(request)
    assert response.status_code == (200 if has_context else 403)
    if has_context:
        team = Teams.objects.get(org=org_a, name="Empty")
        assert team.description == ""
        assert not team.users.exists()
    else:
        assert not Teams.objects.filter(org=org_a, name="Empty").exists()
