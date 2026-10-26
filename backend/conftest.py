"""Shared pytest fixtures for Django CRM backend tests.

The definitions live in :mod:`common.testing` so that they ship inside the
wheel; see that module's docstring for why. This file re-exports them so pytest
discovers the fixtures at the repository root and so the twenty test modules
that already say ``from conftest import rls_org`` keep working.

Every name is listed explicitly rather than star-imported. A star import skips
names beginning with an underscore, which would silently drop
``_use_db`` and ``_restore_rls_context_after_each_request``: both are
``autouse``, so losing them does not fail loudly, it just stops granting
database access and stops restoring the RLS context after each request. That is
not a hypothetical. The enterprise suite re-exported this file with
``from community_conftest import *`` and has been missing both fixtures the
whole time.
"""

import pytest

from common.testing import (  # noqa: F401
    _make_authenticated_client,
    _restore_rls_context_after_each_request,
    _schema_contract,
    _use_db,
    admin_client,
    admin_profile,
    admin_user,
    clear_rls_context,
    org_a,
    org_b,
    org_b_client,
    profile_b,
    regular_user,
    restore_rls_context,
    rls_org,
    set_rls_context,
    unauthenticated_client,
    user_b,
    user_client,
    user_profile,
)


def pytest_addoption(parser):
    parser.addoption(
        "--contract-coverage",
        action="store_true",
        help="Fail a passing full run if any JSON success reply in the API "
        "schema was never checked against a test response.",
    )


def pytest_sessionfinish(session, exitstatus):
    if exitstatus != 0 or not session.config.getoption("--contract-coverage"):
        return
    from common.schema_contract import unchecked_operations

    missing = unchecked_operations()
    if missing:
        report = session.config.pluginmanager.get_plugin("terminalreporter")
        report.write_line(
            "\nCONTRACT-COVERAGE: no test checks the success reply of:", red=True
        )
        for key in missing:
            report.write_line(f"  {key}", red=True)
        session.exitstatus = pytest.ExitCode.TESTS_FAILED
