# Nightshift - Implementation Handoff

## What is Nightshift?

A standalone Phoenix app that automates Claude Code CLI sessions overnight. It polls GitHub Issues from configured repositories, spawns Claude Code in headless mode to implement them, and creates PRs with the results. A LiveView dashboard provides real-time monitoring.

## Tech Stack

- Elixir/Phoenix + LiveView
- Ash Framework + AshSqlite
- Oban + AshOban for job scheduling
- Claude Code CLI (`claude -p`) for headless execution
- GitHub CLI (`gh`) for issue/PR management
- Elixir Port for streaming NDJSON output in real-time

## Current State

- Project bootstrapped via Ash installer with Phoenix + SQLite
- Dependencies installed: ash, ash_phoenix, ash_sqlite, ash_admin, ash_oban, oban_web, live_debugger
- Default branch is `master` — needs renaming to `main`
- No GitHub remote yet — needs `gh repo create`
- No domain modules, resources, or workers yet

## TODO: Remaining Setup

1. Rename branch `master` → `main`
2. Create GitHub repo: `gh repo create nightshift --private --source . --push`
3. Set up CLAUDE.md with project conventions

## TODO: Phase 2 — Data Model (Ash Resources)

Create Ash domain `Nightshift.Automation` with these resources:

### Nightshift.Automation.Project
| Field | Type | Notes |
|-------|------|-------|
| id | uuid_v7 | primary key |
| name | string | e.g. "Paper Trade Pro" |
| repo_path | string | absolute path, e.g. "/home/davidtaing/paper_trade_pro" |
| github_remote | string | e.g. "davidtaing/paper-trade-pro" |
| default_branch | string | default "main" |
| issue_label | string | label to watch, default "nightshift" |
| allowed_tools | string | comma-separated, e.g. "Bash,Read,Write,Edit,Glob,Grep,Agent" |
| max_turns | integer | default 50 |
| max_budget_usd | decimal | default 5.00 |
| active | boolean | default true |

### Nightshift.Automation.Task
| Field | Type | Notes |
|-------|------|-------|
| id | uuid_v7 | primary key |
| project_id | uuid | belongs_to Project |
| github_issue_number | integer | |
| title | string | issue title |
| description | string | issue body (becomes the Claude prompt) |
| status | atom | :pending, :running, :completed, :failed, :cancelled |
| priority | integer | default 0 |

### Nightshift.Automation.Run
| Field | Type | Notes |
|-------|------|-------|
| id | uuid_v7 | primary key |
| task_id | uuid | belongs_to Task |
| worktree_path | string | |
| branch_name | string | |
| exit_code | integer | |
| pr_url | string | nullable |
| started_at | utc_datetime_usec | |
| completed_at | utc_datetime_usec | nullable |
| cost_usd | decimal | nullable |
| turns_used | integer | nullable |
| status | atom | :pending, :running, :succeeded, :failed, :timeout |

### Nightshift.Automation.RunLog
| Field | Type | Notes |
|-------|------|-------|
| id | uuid_v7 | primary key |
| run_id | uuid | belongs_to Run |
| content | string | NDJSON line from Claude output |
| log_type | atom | :stdout, :stderr, :system |
| timestamp | utc_datetime_usec | |

## TODO: Phase 3 — Core Services

### Nightshift.Services.Claude
- `build_args(task, project)` — builds CLI arguments for `claude -p`
- `execute(task, project, run)` — opens Elixir Port, streams NDJSON, writes RunLog records
- Flags to use: `--output-format stream-json`, `--allowedTools`, `--max-turns`, `--max-budget-usd`, `--permission-mode bypassPermissions`
- Must `cd` into the worktree directory before running

### Nightshift.Services.Git
- `create_worktree(project, branch_name)` — `git worktree add`
- `remove_worktree(path)` — `git worktree remove`
- `has_changes?(path)` — check if worktree has uncommitted changes

### Nightshift.Services.GitHub
- `list_issues(project)` — `gh issue list --repo {remote} --label {label} --json number,title,body`
- `create_pr(project, branch, title, body)` — `gh pr create`
- `add_label(project, issue_number, label)` — mark issues as processed
- `close_issue(project, issue_number)` — after PR created

## TODO: Phase 4 — Oban Workers

### IssueSyncWorker (Cron: every 15 minutes or configurable)
1. Fetch all active projects
2. For each, call GitHub.list_issues
3. Deduplicate against existing tasks (by project_id + issue_number)
4. Create Task records for new issues (status: :pending)
5. Enqueue TaskRunnerWorker for each new task

### TaskRunnerWorker
1. Update task status → :running, create Run record (status: :running)
2. Create git worktree: `git worktree add .nightshift/worktrees/{branch} -b nightshift/issue-{number}`
3. Run Claude via Port: `claude -p "{task.description}" --output-format stream-json ...`
4. Stream each NDJSON line → RunLog record + PubSub broadcast for live UI
5. On completion: check exit code, check for changes
6. If changes exist: create PR via `gh pr create`
7. Update Run (status, exit_code, pr_url, cost, turns, completed_at)
8. Update Task status → :completed or :failed
9. Clean up worktree

### CleanupWorker (Cron: daily)
1. Remove worktrees older than 7 days
2. Mark tasks stuck in :running for >2 hours as :failed

## TODO: Phase 5 — LiveView Dashboard

### Pages
- **`/`** — Dashboard: project cards with recent run stats
- **`/projects/:id`** — Project detail: task list, config form
- **`/runs/:id`** — Run detail: live-streaming log output via PubSub, status badge, PR link
- **`/settings`** — Add/edit/remove projects

### Real-time streaming pattern
```elixir
# In TaskRunnerWorker, broadcast each log line:
Phoenix.PubSub.broadcast(Nightshift.PubSub, "run:#{run.id}", {:log, log_entry})

# In RunLive.Show, subscribe on mount:
Phoenix.PubSub.subscribe(Nightshift.PubSub, "run:#{@run.id}")

# Handle incoming logs:
def handle_info({:log, log_entry}, socket) do
  {:noreply, stream_insert(socket, :logs, log_entry)}
end
```

## Claude Code Headless Reference

```bash
# Basic headless execution
claude -p "implement feature X" \
  --output-format stream-json \
  --allowedTools "Bash,Read,Write,Edit,Glob,Grep,Agent" \
  --permission-mode bypassPermissions \
  --max-turns 50 \
  --max-budget-usd 5.00

# The working directory must be set via cd before running
cd /path/to/worktree && claude -p "..."
```

## Key Architecture Decisions
- **SQLite** not Postgres — this is a lightweight standalone tool, no need for a full DB server
- **Ash Framework** — consistent with the developer's other projects
- **Elixir Port** not System.cmd — enables real-time streaming of Claude output to the LiveView dashboard
- **GitHub Issues** as task source — leverages existing workflow, no custom UI needed for task creation
- **Git worktrees** for isolation — each Claude session gets its own copy of the repo
