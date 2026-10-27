# AGENTS.md

Instructions for coding agents other than Claude Code (Codex, Gemini, Vibe). `CLAUDE.md` is the source of truth for this repo; this file only adds what delegated agents need.

## Read first

1. Read `CLAUDE.md` in full before changing anything. Its security rules, house rules and gotchas apply to you exactly as written.
2. For anything under `mobile/`, also read `mobile/CLAUDE.md`.
3. Where a prompt from the planner conflicts with `CLAUDE.md`, stop and say so instead of picking one.

## Non-negotiables

- Do not stage, commit, push, stash, reset or switch branches. Leave changes unstaged for review.
- Stay inside the files and directories the task names. If the task cannot be done without touching others, stop and report why.
- Never weaken a protection (RLS policy, permission class, org filter, validator, CSRF or auth check) to make a test or feature work.
- No em dashes anywhere: code, comments, docs, UI copy, error strings, test names.
- Do not edit `backend/pyproject.toml` or `backend/uv.lock` versions. The planner bumps the version.
- Do not start the dev servers or touch the docker stack. Run tests and checks only.

## Before you report done

Run the checks that cover what you touched, from `CLAUDE.md` Commands, and fix what you broke:

- Backend: `uv run ruff check .`, `uv run ruff format --check .`, and the specific test files with `--no-cov`. The full suite is slow here, so run the files for your change, not everything.
- Frontend: `pnpm run check`, `pnpm run lint`, and the affected vitest files.

## Final report

End with: the files you changed, the commands you ran and their results, anything you skipped or could not verify, and any security concern you noticed (described in the report only, never in a commit message or public text).
