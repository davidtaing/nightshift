# Nightshift - Claude Code Context

## Project Purpose

Automates Claude Code CLI sessions to implement GitHub issues overnight.
Ash + AshSqlite + Oban + Phoenix LiveView on a single SQLite database.

## Key Conventions

- Run `mix precommit` after all changes
- HTTP via `Req` only (no httpoison/tesla)
- Ash domain: `Nightshift.Automation` (registered in config)
- Oban queues: `default`, `sync` (ticket + PR polling), `runner` (Claude implementation)
- Workers live in `lib/nightshift/workers/`
- Services live in `lib/nightshift/services/` (Claude, Git)
- Ticket providers live in `lib/nightshift/providers/` (TicketProvider behaviour + implementations)

## Critical Patterns

- AshOban trigger on Task fires when `status == :pending` — do not manually enqueue TaskRunnerWorker
- Use Elixir Port (not System.cmd) for Claude execution to stream output
- Each Run gets its own git worktree at `.nightshift/worktrees/{branch_name}`
- RunLog rows are inserted via raw Repo calls (not Ash) for performance
- Clean up worktrees on Run completion (success or failure)
- Prompt is built from `project.prompt_template` with `{{ticket_id}}`, `{{github_remote}}`, `{{repo_path}}`, `{{project_name}}` variables
- Ticket source is pluggable via `Nightshift.Providers.TicketProvider` behaviour — never call provider modules directly from workers, always go through the dispatcher
- PR creation is always via `Nightshift.Providers.GitHub.create_pr/4` — GitHub is always the code host
- `"Closes #N"` in PR body auto-closes GitHub Issues on merge; for other providers, `on_completed/3` handles ticket updates

## Do Not

- Do not use System.cmd for Claude execution (no streaming)
- Do not store ANTHROPIC_API_KEY in the database
- Do not allow multiple active Runs for the same Task
- Do not call provider modules directly from workers — route through `TicketProvider` dispatcher
- Do not close tickets programmatically — use `"Closes #N"` in PR body for GitHub; other providers handle it in `on_completed/3`
