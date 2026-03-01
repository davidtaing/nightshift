# Nightshift - Implementation Handoff

## What is Nightshift?

A standalone Phoenix app that automates Claude Code CLI sessions overnight. It:

- **Implements tickets** — polls configured ticket sources (GitHub Issues, Linear, ClickUp, etc.), spawns Claude Code headlessly to implement them, and opens PRs on GitHub
- **Reviews PRs** — watches for `@claude review` comments on open PRs and spawns a headless Claude session to write and post a code review
- **Provides a real-time dashboard** — LiveView UI for monitoring runs, logs, and project status
- **Ships as a Docker image** — self-contained with Claude CLI, gh CLI, and git bundled in; repos are cloned into a persistent data volume

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
- No GitHub remote yet — needs `gh repo create`
- No domain modules, resources, or workers yet
- No CLAUDE.md yet

## Environment Requirements

All of the following are bundled in the Docker image. For local dev without Docker, install them manually.

- **Claude Code CLI**: `claude` in PATH, authenticated via `ANTHROPIC_API_KEY` env var
- **GitHub CLI**: `gh` in PATH, authenticated via `GITHUB_TOKEN` env var (or mount `~/.config/gh`)
- **git**: configured with `user.name` and `user.email` (via env or git config in image)
- **Data volume**: `/data` — contains `nightshift.db`, cloned repos (`/data/repos/`), and worktrees

## Concurrency Model

| Queue | Concurrency | Purpose |
|-------|-------------|---------|
| `runner` | 3 | Claude implementation sessions (heavy — each spawns an OS process) |
| `sync` | 5 | Ticket polling + PR sync (lightweight GitHub CLI calls) |
| `default` | 10 | Cleanup and misc jobs |

---

## TODO: Phase 1 — Remaining Setup

1. Rename branch `master` → `main`: `git branch -m master main`
2. Create GitHub repo: `gh repo create nightshift --private --source . --push`
3. Update Oban queue config (see below)
4. Create CLAUDE.md with project conventions

### Oban Queue Config Update

In `config/config.exs`, replace `queues: [default: 10]` with:

```elixir
queues: [default: 10, sync: 5, runner: 3]
```

### CLAUDE.md Outline

```markdown
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
- AshOban trigger on Task fires when status == :pending — do not manually enqueue TaskRunnerWorker
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
```

---

## TODO: Phase 2 — Data Model (Ash Resources)

### Domain Module

```elixir
# lib/nightshift/automation.ex
defmodule Nightshift.Automation do
  use Ash.Domain

  resources do
    resource Nightshift.Automation.Project
    resource Nightshift.Automation.Task
    resource Nightshift.Automation.Run
    resource Nightshift.Automation.RunLog
  end
end
```

Register in `config/config.exs`:

```elixir
config :nightshift,
  ash_domains: [Nightshift.Automation]
```

---

### Nightshift.Automation.Project

```elixir
defmodule Nightshift.Automation.Project do
  use Ash.Resource,
    domain: Nightshift.Automation,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "projects"
    repo Nightshift.Repo
  end

  actions do
    defaults [:read, :destroy]
    create :create do
      # repo_path is NOT accepted here — set by Git.clone_repo/1 after creation
      accept [:name, :github_remote, :default_branch,
              :ticket_provider, :provider_config, :ticket_label,
              :allowed_tools, :max_turns, :max_budget_usd, :active,
              :prompt_template, :review_prompt_template]
    end

    update :update do
      accept [:name, :github_remote, :default_branch,
              :ticket_provider, :provider_config, :ticket_label,
              :allowed_tools, :max_turns, :max_budget_usd, :active,
              :prompt_template, :review_prompt_template]
    end

    update :set_repo_path do
      accept [:repo_path]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :github_remote, :string, allow_nil?: false    # e.g. "username/my-project" — always GitHub for PRs
    # Auto-set on project creation by Git.clone_repo/1. Not user-editable.
    # In Docker: /data/repos/{project.id}
    attribute :repo_path, :string
    attribute :default_branch, :string, default: "main"
    attribute :ticket_provider, :atom,
      constraints: [one_of: [:github, :linear, :clickup, :trello, :asana]],
      default: :github
    # Provider-specific config: API tokens, board/list/team IDs, etc.
    # Stored as plaintext — acceptable for a personal LAN tool.
    # Do NOT store ANTHROPIC_API_KEY here.
    # Examples:
    #   GitHub:  %{}  (uses gh CLI auth, no extra config needed)
    #   Linear:  %{"api_key" => "lin_...", "team_id" => "TEAM_ID"}
    #   ClickUp: %{"api_key" => "pk_...", "list_id" => "LIST_ID"}
    #   Trello:  %{"api_key" => "...", "api_token" => "...", "list_id" => "LIST_ID"}
    #   Asana:   %{"access_token" => "...", "project_id" => "PROJECT_ID"}
    attribute :provider_config, :map, default: %{}
    attribute :ticket_label, :string, default: "nightshift"  # filter label/tag for ticket fetch
    attribute :allowed_tools, :string,
      default: "Bash,Read,Write,Edit,Glob,Grep,Agent"
    attribute :max_turns, :integer, default: 50
    attribute :max_budget_usd, :decimal, default: Decimal.new("5.00")
    attribute :active, :boolean, default: true
    # Implementation prompt — variables: {{ticket_id}}, {{github_remote}}, {{repo_path}}, {{project_name}}
    attribute :prompt_template, :string,
      default: """
      You are implementing ticket {{ticket_id}} in the {{project_name}} repository.

      Fetch the full ticket details (including comments) before starting work.
      The repository is at {{repo_path}} and the GitHub remote is {{github_remote}}.

      Implement all changes requested in the ticket. Commit your work with a clear, descriptive message.
      """
    # Review prompt — variables: {{pr_number}}, {{pr_title}}, {{github_remote}}, {{project_name}}
    attribute :review_prompt_template, :string,
      default: """
      You are reviewing pull request #{{pr_number}} ("{{pr_title}}") in the {{project_name}} repository.

      Fetch the PR details and diff before starting:
        gh pr view {{pr_number}} --repo {{github_remote}} --json title,body,files,baseRefName,headRefName
        gh pr diff {{pr_number}} --repo {{github_remote}}

      Write a thorough code review covering correctness, code quality, test coverage, security, and performance.
      Format your review as markdown. Be constructive and specific.
      Output ONLY the review text — it will be posted directly as a PR comment.
      """
    timestamps()
  end

  relationships do
    has_many :tasks, Nightshift.Automation.Task
  end
end
```

---

### Nightshift.Automation.Task

```elixir
defmodule Nightshift.Automation.Task do
  use Ash.Resource,
    domain: Nightshift.Automation,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshOban]

  sqlite do
    table "tasks"
    repo Nightshift.Repo
  end

  oban do
    triggers do
      trigger :run do
        worker Nightshift.Workers.TaskRunnerWorker
        where expr(status == :pending)
        queue :runner
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:project_id, :ticket_id, :title, :description, :priority]
      # Status defaults to :pending, which fires the AshOban trigger
    end

    update :mark_running do
      accept []
      change set_attribute(:status, :running)
    end

    update :mark_completed do
      accept []
      change set_attribute(:status, :completed)
    end

    update :mark_failed do
      accept []
      change set_attribute(:status, :failed)
    end

    update :cancel do
      accept []
      change set_attribute(:status, :cancelled)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :ticket_id, :string, allow_nil?: false  # provider-specific: "42", "ENG-123", etc.
    attribute :title, :string, allow_nil?: false
    attribute :description, :string             # becomes the Claude prompt
    attribute :status, :atom,
      constraints: [one_of: [:pending, :running, :completed, :failed, :cancelled]],
      default: :pending
    attribute :priority, :integer, default: 0
    timestamps()
  end

  relationships do
    belongs_to :project, Nightshift.Automation.Project, allow_nil?: false
    has_many :runs, Nightshift.Automation.Run
  end

  identities do
    # Prevents duplicate tasks for the same ticket across syncs
    identity :unique_ticket_per_project, [:project_id, :ticket_id]
  end
end
```

---

### Nightshift.Automation.Run

```elixir
defmodule Nightshift.Automation.Run do
  use Ash.Resource,
    domain: Nightshift.Automation,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "runs"
    repo Nightshift.Repo
  end

  actions do
    defaults [:read]

    create :start do
      accept [:task_id, :worktree_path, :branch_name]
      change set_attribute(:status, :running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :complete do
      accept [:exit_code, :pr_url, :cost_usd, :turns_used]
      change set_attribute(:status, :succeeded)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    update :fail do
      accept [:exit_code]
      change set_attribute(:status, :failed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    update :timeout do
      accept []
      change set_attribute(:status, :timeout)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :worktree_path, :string
    attribute :branch_name, :string
    attribute :exit_code, :integer
    attribute :pr_url, :string
    attribute :started_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :cost_usd, :decimal
    attribute :turns_used, :integer
    attribute :status, :atom,
      constraints: [one_of: [:pending, :running, :succeeded, :failed, :timeout]],
      default: :running
    timestamps()
  end

  relationships do
    belongs_to :task, Nightshift.Automation.Task, allow_nil?: false
    has_many :logs, Nightshift.Automation.RunLog
  end
end
```

---

### Nightshift.Automation.RunLog

Note: Use raw `Repo.insert_all` for RunLog during active runs — high-volume inserts during a Claude session would be slow through the Ash action layer.

```elixir
defmodule Nightshift.Automation.RunLog do
  use Ash.Resource,
    domain: Nightshift.Automation,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "run_logs"
    repo Nightshift.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:run_id, :content, :log_type]
      change set_attribute(:timestamp, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :content, :string, allow_nil?: false
    attribute :log_type, :atom,
      constraints: [one_of: [:stdout, :stderr, :system]],
      default: :stdout
    attribute :timestamp, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :run, Nightshift.Automation.Run, allow_nil?: false
  end
end
```

**Raw insert for high-frequency logging:**

```elixir
# In TaskRunnerWorker, use Repo.insert_all for RunLog rows
Nightshift.Repo.insert_all("run_logs", [
  %{
    id: Ash.UUIDv7.generate(),
    run_id: run.id,
    content: ndjson_line,
    log_type: :stdout,
    timestamp: DateTime.utc_now(),
    inserted_at: DateTime.utc_now(),
    updated_at: DateTime.utc_now()
  }
])
```

---

### Nightshift.Automation.PRReview

Tracks the lifecycle of a PR through the review-then-fix workflow. Nightshift **triggers** the review by posting `@claude review`; a GitHub Actions workflow in the managed repo actually runs Claude and posts the result. Nightshift then polls for the review and creates a follow-up Task to address any issues.

```
Status flow:
  :awaiting_review   — Nightshift has posted "@claude review"; waiting for GitHub Actions to respond
  :review_received   — Review comment found and cached
  :no_issues         — Review posted but no actionable issues identified
  :follow_up_created — Follow-up Task created to address the review issues
```

```elixir
defmodule Nightshift.Automation.PRReview do
  use Ash.Resource,
    domain: Nightshift.Automation,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "pr_reviews"
    repo Nightshift.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:project_id, :pr_number, :pr_title, :pr_url, :pr_branch]
      change set_attribute(:status, :awaiting_review)
    end

    update :mark_review_received do
      accept [:review_comment_body, :review_comment_id]
      change set_attribute(:status, :review_received)
    end

    update :mark_no_issues do
      accept []
      change set_attribute(:status, :no_issues)
    end

    update :mark_follow_up_created do
      accept [:follow_up_task_id]
      change set_attribute(:status, :follow_up_created)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :pr_number, :string, allow_nil?: false
    attribute :pr_title, :string
    attribute :pr_url, :string
    attribute :pr_branch, :string                 # for follow-up task context
    attribute :review_comment_id, :string         # GitHub comment ID from the review
    attribute :review_comment_body, :string        # cached review text
    attribute :follow_up_task_id, :string         # Task.id for the follow-up run
    attribute :status, :atom,
      constraints: [one_of: [:awaiting_review, :review_received, :no_issues, :follow_up_created]],
      default: :awaiting_review
    timestamps()
  end

  relationships do
    belongs_to :project, Nightshift.Automation.Project, allow_nil?: false
  end

  identities do
    # One review workflow per PR per project
    identity :unique_pr_per_project, [:project_id, :pr_number]
  end
end
```

Also register in the domain:

```elixir
resources do
  resource Nightshift.Automation.Project
  resource Nightshift.Automation.Task
  resource Nightshift.Automation.Run
  resource Nightshift.Automation.RunLog
  resource Nightshift.Automation.PRReview   # add this
end
```

---

## TODO: Phase 3 — Core Services

### Nightshift.Services.Claude

Key responsibility: spawn `claude -p` via Elixir Port, stream NDJSON output, and extract final metrics.

**`--output-format stream-json` event types:**

Each line of stdout is a JSON object with a `"type"` field:

| type | subtype | Notes |
|------|---------|-------|
| `"system"` | `"init"` | First line — contains session_id, tools, model |
| `"assistant"` | — | Claude response turn |
| `"user"` | — | Tool result turn |
| `"result"` | `"success"` | Final line on success — has `cost_usd`, `num_turns`, `result` |
| `"result"` | `"error_max_turns"` | Stopped at turn limit |
| `"result"` | `"error_during_generation"` | Claude API error |

Parse the `"result"` line to extract `cost_usd` and `num_turns` for the Run record.

**Port communication pattern:**

```elixir
defmodule Nightshift.Services.Claude do
  def build_prompt(task, project) do
    project.prompt_template
    |> String.replace("{{ticket_id}}", to_string(task.ticket_id))
    |> String.replace("{{github_remote}}", project.github_remote)
    |> String.replace("{{repo_path}}", project.repo_path)
    |> String.replace("{{project_name}}", project.name)
  end

  def build_args(task, project) do
    prompt = build_prompt(task, project)
    tools = project.allowed_tools
    max_turns = to_string(project.max_turns)
    budget = Decimal.to_string(project.max_budget_usd)

    ~w(
      -p #{prompt}
      --output-format stream-json
      --allowedTools #{tools}
      --permission-mode bypassPermissions
      --max-turns #{max_turns}
      --max-budget-usd #{budget}
    )
  end

  def execute(task, project, run, pid_to_notify) do
    args = build_args(task, project)
    cmd = "cd #{run.worktree_path} && claude #{Enum.join(args, " ")}"

    port = Port.open({:spawn, cmd}, [:binary, :exit_status, {:line, 200_000}])
    stream_loop(port, run, pid_to_notify, %{cost_usd: nil, turns_used: nil})
  end

  defp stream_loop(port, run, pid, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        handle_line(line, run, pid)
        acc = maybe_extract_result(line, acc)
        stream_loop(port, run, pid, acc)

      {^port, {:data, {:noeol, _partial}}} ->
        # Partial line (buffer overflow) — skip or buffer
        stream_loop(port, run, pid, acc)

      {^port, {:exit_status, exit_code}} ->
        {:ok, Map.put(acc, :exit_code, exit_code)}
    after
      # Timeout: kill port if Claude hangs
      :timer.hours(2) ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp handle_line(line, run, pid) do
    # Insert RunLog row
    Nightshift.Repo.insert_all("run_logs", [
      %{
        id: Ash.UUIDv7.generate(),
        run_id: run.id,
        content: line,
        log_type: :stdout,
        timestamp: DateTime.utc_now(),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    # Broadcast for LiveView
    Phoenix.PubSub.broadcast(
      Nightshift.PubSub,
      "run:#{run.id}",
      {:log, %{content: line, log_type: :stdout, timestamp: DateTime.utc_now()}}
    )
  end

  defp maybe_extract_result(line, acc) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result", "cost_usd" => cost, "num_turns" => turns}} ->
        %{acc | cost_usd: Decimal.from_float(cost), turns_used: turns}
      _ ->
        acc
    end
  end
end
```

---

### Nightshift.Services.Git

```elixir
defmodule Nightshift.Services.Git do
  @worktree_base ".nightshift/worktrees"
  @data_dir Application.compile_env(:nightshift, :data_dir, "/data")

  # Called after Project.create — clones the repo and sets project.repo_path
  def clone_repo(project) do
    path = Path.join([@data_dir, "repos", project.id])
    File.mkdir_p!(Path.dirname(path))
    url = "https://github.com/#{project.github_remote}.git"
    case System.cmd("git", ["clone", url, path], stderr_to_stdout: true) do
      {_, 0} ->
        Ash.update!(project, %{repo_path: path}, action: :set_repo_path)
        {:ok, path}
      {output, code} ->
        {:error, {code, output}}
    end
  end

  def worktree_path(project, branch_name) do
    Path.join([project.repo_path, @worktree_base, branch_name])
  end

  def create_worktree(project, branch_name) do
    path = worktree_path(project, branch_name)
    cmd = "git -C #{project.repo_path} worktree add #{path} -b #{branch_name}"
    case System.cmd("bash", ["-c", cmd], stderr_to_stdout: true) do
      {_, 0} -> {:ok, path}
      {output, code} -> {:error, {code, output}}
    end
  end

  def remove_worktree(project, path) do
    # --force in case of unclean state
    cmd = "git -C #{project.repo_path} worktree remove --force #{path}"
    System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)
    :ok
  end

  def has_changes?(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain"]) do
      {"", 0} -> false
      {_, _} -> true
    end
  end
end
```

---

### Nightshift.Providers.TicketProvider

Defines the behaviour all ticket sources must implement, plus a dispatcher that routes to the correct implementation based on `project.ticket_provider`.

```elixir
defmodule Nightshift.Providers.TicketProvider do
  @moduledoc """
  Behaviour for pluggable ticket sources (GitHub Issues, Linear, ClickUp, Trello, Asana).
  PR creation is always via GitHub — it is NOT part of this behaviour.
  """

  @type ticket :: %{
    id: String.t(),       # provider-specific: "42", "ENG-123", "abc123def", etc.
    title: String.t(),
    description: String.t()
  }

  @doc "Fetch open tickets tagged for Nightshift processing."
  @callback list_tickets(project :: map()) :: {:ok, [ticket()]} | {:error, term()}

  @doc "Called when a Task is created (status: :pending). E.g. add a 'queued' label."
  @callback on_queued(project :: map(), ticket_id :: String.t()) :: :ok

  @doc "Called when the TaskRunnerWorker starts. E.g. transition label to 'in-progress'."
  @callback on_started(project :: map(), ticket_id :: String.t()) :: :ok

  @doc "Called when the run succeeds and a PR has been created (pr_url may be nil if no changes)."
  @callback on_completed(project :: map(), ticket_id :: String.t(), pr_url :: String.t() | nil) :: :ok

  @doc "Called when the run fails or times out."
  @callback on_failed(project :: map(), ticket_id :: String.t()) :: :ok

  # Dispatcher — routes to the correct provider module
  def provider_for(%{ticket_provider: :github}),  do: Nightshift.Providers.GitHub
  def provider_for(%{ticket_provider: :linear}),  do: Nightshift.Providers.Linear
  def provider_for(%{ticket_provider: :clickup}), do: Nightshift.Providers.ClickUp
  def provider_for(%{ticket_provider: :trello}),  do: Nightshift.Providers.Trello
  def provider_for(%{ticket_provider: :asana}),   do: Nightshift.Providers.Asana

  def list_tickets(project),                      do: provider_for(project).list_tickets(project)
  def on_queued(project, id),                     do: provider_for(project).on_queued(project, id)
  def on_started(project, id),                    do: provider_for(project).on_started(project, id)
  def on_completed(project, id, pr_url),          do: provider_for(project).on_completed(project, id, pr_url)
  def on_failed(project, id),                     do: provider_for(project).on_failed(project, id)
end
```

---

### Nightshift.Providers.GitHub

Implements `TicketProvider` using GitHub Issues + labels. `create_pr/4` is kept here as a shared function called directly by workers (not part of the behaviour — PR is always GitHub).

```elixir
defmodule Nightshift.Providers.GitHub do
  @behaviour Nightshift.Providers.TicketProvider

  # Labels — must exist in each managed repo before first sync.
  @label_queued      "nightshift:queued"
  @label_in_progress "nightshift:in-progress"
  @label_pr_open     "nightshift:pr-open"
  @label_failed      "nightshift:failed"

  @impl true
  def list_tickets(project) do
    cmd = ~w(
      gh issue list
      --repo #{project.github_remote}
      --label #{project.ticket_label}
      --state open
      --json number,title,body
    )
    case System.cmd("gh", cmd, stderr_to_stdout: true) do
      {json, 0} ->
        {:ok, issues} = Jason.decode(json)
        tickets = Enum.map(issues, fn %{"number" => n, "title" => t, "body" => b} ->
          %{id: to_string(n), title: t, description: b}
        end)
        {:ok, tickets}
      {output, code} ->
        {:error, {code, output}}
    end
  end

  @impl true
  def on_queued(project, ticket_id) do
    add_label(project, ticket_id, @label_queued)
  end

  @impl true
  def on_started(project, ticket_id) do
    transition_label(project, ticket_id, @label_queued, @label_in_progress)
  end

  @impl true
  def on_completed(project, ticket_id, _pr_url) do
    transition_label(project, ticket_id, @label_in_progress, @label_pr_open)
  end

  @impl true
  def on_failed(project, ticket_id) do
    transition_label(project, ticket_id, @label_in_progress, @label_failed)
  end

  # --- PR creation (always GitHub, called directly by TaskRunnerWorker) ---

  def create_pr(project, branch, title, body) do
    cmd = ~w(
      gh pr create
      --repo #{project.github_remote}
      --head #{branch}
      --base #{project.default_branch}
      --title #{title}
      --body #{body}
    )
    case System.cmd("gh", cmd, stderr_to_stdout: true) do
      {pr_url, 0} -> {:ok, String.trim(pr_url)}
      {output, code} -> {:error, {code, output}}
    end
  end

  # --- Private helpers ---

  defp add_label(project, ticket_id, label) do
    System.cmd("gh", ~w(issue edit #{ticket_id} --repo #{project.github_remote} --add-label #{label}))
    :ok
  end

  defp remove_label(project, ticket_id, label) do
    System.cmd("gh", ~w(issue edit #{ticket_id} --repo #{project.github_remote} --remove-label #{label}))
    :ok
  end

  defp transition_label(project, ticket_id, from_label, to_label) do
    remove_label(project, ticket_id, from_label)
    add_label(project, ticket_id, to_label)
  end
end
```

#### Adding future providers

Each new provider (Linear, ClickUp, etc.) is a module that `@behaviour Nightshift.Providers.TicketProvider` and implements the five callbacks. The `provider_config` map on the Project holds any API tokens and IDs the provider needs. No other files need changing.

---

## TODO: Phase 4 — Oban Workers

### Config: Register AshOban and add queues

```elixir
# config/config.exs
config :nightshift, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  queues: [default: 10, sync: 5, runner: 3],
  repo: Nightshift.Repo,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {"*/15 * * * *", Nightshift.Workers.TicketSyncWorker},
      {"*/15 * * * *", Nightshift.Workers.PRSyncWorker},
      {"0 3 * * *",    Nightshift.Workers.CleanupWorker}
    ]}
  ]
```

---

### TicketSyncWorker

```elixir
defmodule Nightshift.Workers.TicketSyncWorker do
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 10 * 60]  # Prevent duplicate syncs within 10 minutes

  @impl Oban.Worker
  def perform(_job) do
    projects = Ash.read!(Nightshift.Automation.Project, filter: [active: true])

    Enum.each(projects, fn project ->
      case Nightshift.Providers.TicketProvider.list_tickets(project) do
        {:ok, tickets} -> sync_tickets(project, tickets)
        {:error, reason} -> Logger.warning("Ticket sync failed for #{project.name}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp sync_tickets(project, tickets) do
    Enum.each(tickets, fn %{id: ticket_id, title: title, description: desc} ->
      # upsert — identity on [project_id, ticket_id] skips duplicates
      case Ash.create(Nightshift.Automation.Task, %{
        project_id: project.id,
        ticket_id: ticket_id,
        title: title,
        description: desc
      }, upsert?: true, upsert_identity: :unique_ticket_per_project, return_skipped_upsert?: true) do
        {:ok, task} when task.status == :pending ->
          # Newly created task — notify provider (e.g. add "queued" label)
          # AshOban trigger also fires automatically
          Nightshift.Providers.TicketProvider.on_queued(project, ticket_id)

        _ ->
          # Already exists — do nothing
          :ok
      end
    end)
  end
end
```

---

### TaskRunnerWorker

AshOban enqueues this automatically when a Task is created with `status: :pending`. The job receives `%{"ash_id" => task_id}` when triggered via AshOban.

```elixir
defmodule Nightshift.Workers.TaskRunnerWorker do
  use Oban.Worker,
    queue: :runner,
    max_attempts: 1  # Don't auto-retry — failed runs should be reviewed

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ash_id" => task_id}}) do
    task = Ash.get!(Nightshift.Automation.Task, task_id, load: [:project])
    project = task.project
    alias Nightshift.Providers.TicketProvider

    # 1. Mark task as running; notify provider (e.g. transition label to in-progress)
    Ash.update!(task, action: :mark_running)
    TicketProvider.on_started(project, task.ticket_id)

    # 2. Create git worktree
    branch = "nightshift/ticket-#{task.ticket_id}"
    {:ok, worktree_path} = Nightshift.Services.Git.create_worktree(project, branch)

    # 3. Create Run record
    run = Ash.create!(Nightshift.Automation.Run, %{
      task_id: task.id,
      worktree_path: worktree_path,
      branch_name: branch
    }, action: :start)

    # 4. Execute Claude
    result = Nightshift.Services.Claude.execute(task, project, run, self())

    # 5. Handle result
    case result do
      {:ok, %{exit_code: 0, cost_usd: cost, turns_used: turns}} ->
        pr_url = maybe_create_pr(project, run, branch, task)
        Ash.update!(run, %{exit_code: 0, cost_usd: cost, turns_used: turns, pr_url: pr_url}, action: :complete)
        Ash.update!(task, action: :mark_completed)
        TicketProvider.on_completed(project, task.ticket_id, pr_url)

      {:ok, %{exit_code: code}} ->
        Ash.update!(run, %{exit_code: code}, action: :fail)
        Ash.update!(task, action: :mark_failed)
        TicketProvider.on_failed(project, task.ticket_id)

      {:error, :timeout} ->
        Ash.update!(run, action: :timeout)
        Ash.update!(task, action: :mark_failed)
        TicketProvider.on_failed(project, task.ticket_id)
    end

    # 6. Clean up worktree
    Nightshift.Services.Git.remove_worktree(project, worktree_path)

    :ok
  rescue
    e ->
      Logger.error("TaskRunnerWorker crashed: #{inspect(e)}")
      reraise e, __STACKTRACE__
  end

  # PR creation is always via GitHub regardless of ticket provider.
  # "Closes #N" syntax only auto-closes GitHub Issues — for other providers
  # the on_completed/3 callback handles the ticket-side update.
  defp maybe_create_pr(project, run, branch, task) do
    if Nightshift.Services.Git.has_changes?(run.worktree_path) do
      title = "nightshift: #{task.title}"
      body = """
      Closes ##{task.ticket_id}

      Automated implementation by [Nightshift](https://github.com/davidtaing/nightshift).
      """
      case Nightshift.Providers.GitHub.create_pr(project, branch, title, body) do
        {:ok, pr_url} -> pr_url
        {:error, reason} ->
          Logger.warning("PR creation failed for #{branch}: #{inspect(reason)}")
          nil
      end
    end
  end
end
```

---

### CleanupWorker

```elixir
defmodule Nightshift.Workers.CleanupWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    # 1. Mark tasks stuck in :running for >2 hours as :failed
    cutoff = DateTime.add(DateTime.utc_now(), -2, :hour)
    stuck_runs =
      Ash.read!(Nightshift.Automation.Run,
        filter: [status: :running, started_at: [less_than: cutoff]])

    Enum.each(stuck_runs, fn run ->
      Ash.update!(run, action: :timeout)
      task = Ash.get!(Nightshift.Automation.Task, run.task_id)
      Ash.update!(task, action: :mark_failed)

      # Attempt worktree cleanup
      task_with_project = Ash.load!(task, :project)
      Nightshift.Services.Git.remove_worktree(task_with_project.project, run.worktree_path)
    end)

    :ok
  end
end
```

---

## TODO: Phase 5 — LiveView Dashboard

### Router

```elixir
scope "/", NightshiftWeb do
  pipe_through :browser

  live "/", DashboardLive, :index
  live "/projects/:id", ProjectLive, :show
  live "/projects/:id/edit", ProjectLive, :edit
  live "/runs/:id", RunLive, :show
  live "/settings", SettingsLive, :index
end
```

### Pages

- **`/`** (`DashboardLive`) — Project cards with recent run stats and status badges
- **`/projects/:id`** (`ProjectLive`) — Task list, config form, sync trigger button
- **`/runs/:id`** (`RunLive`) — Live-streaming log output, status badge, PR link
- **`/settings`** (`SettingsLive`) — Add/edit/remove projects

### Real-time streaming pattern

Use `Phoenix.LiveView.stream/3` for RunLog — it handles large lists without memory issues.

```elixir
# In RunLive.Show, mount:
def mount(%{"id" => run_id}, _session, socket) do
  run = Ash.get!(Nightshift.Automation.Run, run_id, load: [:task, :logs])
  if connected?(socket), do: Phoenix.PubSub.subscribe(Nightshift.PubSub, "run:#{run_id}")

  socket =
    socket
    |> assign(:run, run)
    |> stream(:logs, run.logs)

  {:ok, socket}
end

# Handle incoming log lines broadcast by TaskRunnerWorker:
def handle_info({:log, log_entry}, socket) do
  {:noreply, stream_insert(socket, :logs, log_entry)}
end
```

```heex
<%!-- RunLive template --%>
<div id="run-logs" phx-update="stream" class="font-mono text-sm space-y-0.5">
  <div :for={{id, log} <- @streams.logs} id={id}
       class={[
         "px-2 py-0.5",
         log.log_type == :stderr && "text-red-400",
         log.log_type == :system && "text-yellow-400 italic",
         log.log_type == :stdout && "text-green-300"
       ]}>
    <span class="text-zinc-500 text-xs mr-2">{Calendar.strftime(log.timestamp, "%H:%M:%S")}</span>
    {log.content}
  </div>
</div>
```

---

## Error Scenarios

| Scenario | Expected Behavior |
|----------|-------------------|
| Claude exits non-zero | Run → :failed, Task → :failed, worktree cleaned up |
| Claude hits `--max-turns` | Exit code non-zero, result type is `error_max_turns`, same as above |
| Claude hits `--max-budget-usd` | Exit code non-zero, result type is `error_during_generation` |
| Port timeout (2h) | Run → :timeout, Task → :failed, Port.close called |
| `git worktree add` fails | Worker reraises, Oban marks job failed, Task stays :running (CleanupWorker fixes) |
| `gh pr create` fails | Run marked complete without pr_url, warning logged |
| `gh issue list` fails | TicketSyncWorker logs warning, continues to next project |
| App crashes mid-run | CleanupWorker marks stuck runs as :timeout on next daily run |
| Duplicate issue sync | Task upsert with `upsert?: true` is a no-op for existing tasks |

---

## Testing Strategy

- **Services**: Use `System.cmd` mock or test against real CLIs in integration tests
- **Workers**: Use `Oban.Testing` helpers (`perform_job/2`)
- **LiveView**: Use `Phoenix.LiveViewTest` + `LazyHTML` per AGENTS.md
- **Ash Resources**: Test actions directly via `Ash.create/update/read`

```elixir
# Test TicketSyncWorker creates tasks
test "syncs new tickets as pending tasks" do
  project = create_project()
  # mock TicketProvider.list_tickets to return fixtures
  assert :ok = perform_job(TicketSyncWorker, %{})
  assert [task] = Ash.read!(Task, filter: [project_id: project.id])
  assert task.status == :pending
end
```

Run with: `mix test` or `mix test --failed` for reruns.

---

## TODO: Phase 6 — PR Review Automation

**Design principle: polling only. No webhooks, no inbound internet traffic. Nightshift triggers the review; GitHub Actions runs it.**

### Overview

```
[Nightshift PRSyncWorker]  →  posts "@claude review" on new open PRs
        ↓
[GitHub Actions in managed repo]  →  claude-code-action runs the review, posts result as comment
        ↓
[Nightshift PRSyncWorker]  →  polls for review comment, creates follow-up Task to address issues
        ↓
[TaskRunnerWorker]  →  Claude fixes the issues, opens a new PR (or updates the existing branch)
```

### Prerequisite: GitHub Actions workflow in each managed repo

Each repo Nightshift manages needs this workflow. Nightshift does not install it — it must be added manually once per repo.

```yaml
# .github/workflows/claude-review.yml
# Add this to each repo Nightshift manages.
name: Claude Code Review

on:
  issue_comment:
    types: [created]

jobs:
  review:
    # Only run on PR comments containing "@claude review"
    if: |
      github.event.issue.pull_request &&
      contains(github.event.comment.body, '@claude review')
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: anthropics/claude-code-action@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

The action posts its review as a PR comment from `github-actions[bot]`. Nightshift detects this comment on the next poll cycle.

### PRSyncWorker

Single worker with three responsibilities per poll cycle:

1. **Trigger**: Find open PRs with no `PRReview` record → post `@claude review`, create `PRReview` (status: `:awaiting_review`)
2. **Collect**: Find `PRReview` records in `:awaiting_review` → poll for a review comment from `github-actions[bot]`, update status to `:review_received`
3. **Follow up**: Find `PRReview` records in `:review_received` → create a follow-up `Task`, update status to `:follow_up_created`

```elixir
defmodule Nightshift.Workers.PRSyncWorker do
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 14 * 60]

  @impl Oban.Worker
  def perform(_job) do
    projects = Ash.read!(Nightshift.Automation.Project, filter: [active: true])
    Enum.each(projects, &sync_project_prs/1)
    :ok
  end

  defp sync_project_prs(project) do
    case fetch_open_prs(project) do
      {:ok, prs} ->
        trigger_new_reviews(project, prs)
        collect_completed_reviews(project)
        create_follow_up_tasks(project)
      {:error, reason} ->
        Logger.warning("PR sync failed for #{project.name}: #{inspect(reason)}")
    end
  end

  # --- Step 1: Trigger ---

  defp fetch_open_prs(project) do
    cmd = ~w(gh pr list --repo #{project.github_remote} --state open --json number,title,url,headRefName)
    case System.cmd("gh", cmd, stderr_to_stdout: true) do
      {json, 0} -> Jason.decode(json)
      {output, code} -> {:error, {code, output}}
    end
  end

  # Nightshift's own PRs have branches starting with "nightshift/".
  # Reviewing them would create a follow-up task → new PR → review → follow-up ... loop.
  defp nightshift_owned_branch?(branch_name) do
    String.starts_with?(branch_name || "", "nightshift/")
  end

  defp trigger_new_reviews(project, prs) do
    existing_pr_numbers =
      Ash.read!(Nightshift.Automation.PRReview, filter: [project_id: project.id])
      |> Enum.map(& &1.pr_number)
      |> MapSet.new()

    prs
    |> Enum.reject(fn pr -> MapSet.member?(existing_pr_numbers, to_string(pr["number"])) end)
    |> Enum.reject(fn pr -> nightshift_owned_branch?(pr["headRefName"]) end)
    |> Enum.each(fn pr ->
      pr_number = to_string(pr["number"])

      # Post "@claude review" to trigger GitHub Actions
      System.cmd("gh", ~w(pr comment #{pr_number} --repo #{project.github_remote} --body @claude review))

      # Track it
      Ash.create!(Nightshift.Automation.PRReview, %{
        project_id: project.id,
        pr_number: pr_number,
        pr_title: pr["title"],
        pr_url: pr["url"],
        pr_branch: pr["headRefName"]
      })
    end)
  end

  # --- Step 2: Collect ---

  defp collect_completed_reviews(project) do
    awaiting =
      Ash.read!(Nightshift.Automation.PRReview,
        filter: [project_id: project.id, status: :awaiting_review])

    Enum.each(awaiting, fn review ->
      case fetch_review_comment(project, review.pr_number) do
        {:ok, comment} ->
          Ash.update!(review, %{
            review_comment_id: to_string(comment["id"]),
            review_comment_body: comment["body"]
          }, action: :mark_review_received)
        :not_found ->
          :ok  # Still waiting for GitHub Actions
      end
    end)
  end

  defp fetch_review_comment(project, pr_number) do
    cmd = ~w(gh pr view #{pr_number} --repo #{project.github_remote} --json comments)
    case System.cmd("gh", cmd, stderr_to_stdout: true) do
      {json, 0} ->
        {:ok, parsed} = Jason.decode(json)
        comments = parsed["comments"] || []
        # Find a substantive comment from github-actions[bot] (the Claude review)
        review_comment =
          Enum.find(comments, fn c ->
            (c["author"]["login"] == "github-actions[bot]") and
            String.length(c["body"] || "") > 200
          end)
        if review_comment, do: {:ok, review_comment}, else: :not_found
      _ ->
        :not_found
    end
  end

  # --- Step 3: Follow up ---

  defp create_follow_up_tasks(project) do
    received =
      Ash.read!(Nightshift.Automation.PRReview,
        filter: [project_id: project.id, status: :review_received])

    Enum.each(received, fn review ->
      description = build_follow_up_description(review)

      case Ash.create(Nightshift.Automation.Task, %{
        project_id: project.id,
        ticket_id: "pr-review-#{review.pr_number}",
        title: "Address review issues: #{review.pr_title}",
        description: description
      }) do
        {:ok, task} ->
          Ash.update!(review, %{follow_up_task_id: task.id}, action: :mark_follow_up_created)
        {:error, reason} ->
          Logger.warning("Failed to create follow-up task for PR #{review.pr_number}: #{inspect(reason)}")
      end
    end)
  end

  defp build_follow_up_description(review) do
    """
    Address the code review issues identified for PR ##{review.pr_number} ("#{review.pr_title}").
    The PR branch is: #{review.pr_branch}

    Review feedback:
    #{review.review_comment_body}

    Please fix all issues raised in the review. You may push directly to branch #{review.pr_branch}
    or create a new branch if that is more appropriate.
    """
  end
end
```

### LiveView: PRReviews list

Add `/reviews` to the dashboard and link from `ProjectLive`. Each row shows: PR title, PR number, status badge, link to the PR, link to the follow-up task (if created).

---

## TODO: Phase 7 — Docker / Deployment

### Dockerfile

Multi-stage build. The runtime image bundles Elixir release + Claude CLI + gh CLI + git.

```dockerfile
# Stage 1: Elixir build
FROM hexpm/elixir:1.17.3-erlang-27.1-debian-bookworm-20240904-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y build-essential nodejs npm git
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY . .
RUN MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release

# Stage 2: Runtime
FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y \
    libssl3 libncurses6 locales \
    curl git \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=...] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh

# Install Claude CLI
RUN npm install -g @anthropic-ai/claude-code

# Configure git
RUN git config --global user.email "nightshift@bot.local" \
    && git config --global user.name "Nightshift"

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/nightshift ./

VOLUME /data
EXPOSE 4000

CMD ["bin/nightshift", "start"]
```

### docker-compose.yml

```yaml
services:
  nightshift:
    build: .
    ports:
      - "4000:4000"
    volumes:
      - nightshift_data:/data
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - GITHUB_TOKEN=${GITHUB_TOKEN}
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - PHX_HOST=${PHX_HOST:-localhost}
      - DATABASE_PATH=/data/nightshift.db
      - PHX_SERVER=true
    restart: unless-stopped

volumes:
  nightshift_data:
```

### config/runtime.exs additions

```elixir
config :nightshift,
  data_dir: System.get_env("DATA_DIR", "/data")

# Configure gh CLI to use GITHUB_TOKEN when present
# (gh picks it up automatically from the environment)
```

### Project creation flow with Docker

When a project is created in the UI:
1. `Ash.create(Project, params)` — inserts the record (no `repo_path` yet)
2. Trigger `Git.clone_repo(project)` synchronously in the Settings LiveView (or via Oban job)
3. `set_repo_path` action updates the record with the cloned path
4. Project becomes active once `repo_path` is set

---

## TODO: Phase 8 — Terminal Emulator (Optional)

Provides a browser-based shell into the running container for debugging, without needing `docker exec`.

### Architecture

- **Frontend**: `xterm.js` (import via `npm install --prefix assets @xterm/xterm`)
- **Channel**: `NightshiftWeb.TerminalChannel` — Phoenix Channel that opens a PTY via Elixir Port and relays bytes bidirectionally
- **Route**: `socket "/terminal"` in endpoint + `live "/terminal", TerminalLive`

### TerminalChannel

```elixir
defmodule NightshiftWeb.TerminalChannel do
  use Phoenix.Channel

  def join("terminal:session", _params, socket) do
    port = Port.open({:spawn, "/bin/bash"}, [
      :binary,
      :exit_status,
      {:env, [{'TERM', 'xterm-256color'}]},
      :use_stdio,
      :stderr_to_stdout
    ])
    {:ok, assign(socket, :port, port)}
  end

  # Client → Shell
  def handle_in("input", %{"data" => data}, socket) do
    Port.command(socket.assigns.port, data)
    {:noreply, socket}
  end

  # Shell → Client
  def handle_info({port, {:data, data}}, socket) when port == socket.assigns.port do
    push(socket, "output", %{"data" => data})
    {:noreply, socket}
  end

  def handle_info({port, {:exit_status, _}}, socket) when port == socket.assigns.port do
    push(socket, "exit", %{})
    {:stop, :normal, socket}
  end
end
```

### Frontend (assets/js/terminal.js)

```javascript
import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"

const TerminalHook = {
  mounted() {
    const term = new Terminal({ cursorBlink: true })
    const fitAddon = new FitAddon()
    term.loadAddon(fitAddon)
    term.open(this.el)
    fitAddon.fit()

    const channel = this.liveSocket.channel("terminal:session", {})
    channel.join()
    channel.on("output", ({ data }) => term.write(data))
    channel.on("exit", () => term.writeln("\r\n[session ended]"))
    term.onData(data => channel.push("input", { data }))
  }
}
export default TerminalHook
```

Add to `app.js`:
```javascript
import TerminalHook from "./terminal"
// add to hooks object: { TerminalHook, ...otherHooks }
```

---

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

---

## Key Architecture Decisions

- **SQLite** not Postgres — this is a lightweight standalone tool, no need for a full DB server
- **Ash Framework** — consistent with the developer's other projects
- **Elixir Port** not System.cmd — enables real-time streaming of Claude output to the LiveView dashboard
- **Pluggable ticket providers** (`Nightshift.Providers.TicketProvider` behaviour) — ticket source is decoupled from code hosting. GitHub Issues is the default provider; Linear, ClickUp, Trello, Asana follow the same five-callback interface. New providers only require one new module.
- **GitHub is always the code host** — PRs are always created via `gh pr create` regardless of ticket source. This is intentional: code always lives in a git repo with a GitHub remote.
- **Git worktrees** for isolation — each Claude session gets its own copy of the repo
- **AshOban trigger** on Task — avoids manual job enqueueing; firing on `status == :pending` is idempotent
- **`max_attempts: 1`** for TaskRunnerWorker — failed Claude runs should not auto-retry; human review expected
- **Raw `Repo.insert_all`** for RunLog — avoids Ash action overhead for high-frequency log inserts
- **`ticket_id` is a string on Task** — accommodates all provider ID formats: GitHub numeric ("42"), Linear slug ("ENG-123"), ClickUp alphanumeric, etc.
- **`unique_by [:project_id, :ticket_id]`** on Task — upsert-safe deduplication across syncs
- **No authentication** — LAN-only home server deployment; not exposed to the internet. In `config/runtime.exs`, bind to the LAN interface or `0.0.0.0` and rely on network-level access control
- **Configurable `prompt_template` per Project** — template variables replaced at runtime; Claude fetches the full issue (with comments) itself via `gh issue view`, so the prompt stays minimal and always reflects the current issue state
- **GitHub Issues lifecycle** uses labels (`nightshift:queued/in-progress/pr-open/failed`) managed by `Providers.GitHub`; other providers translate the same four lifecycle events to their own state model (Linear states, ClickUp statuses, Trello card moves, etc.)
- **GitHub label prerequisites** — the four `nightshift:*` labels must exist in each managed GitHub repo before the first sync. Document as a manual setup step or add a `Providers.GitHub.ensure_labels/1` helper
- **Polling-only, no inbound traffic** — Nightshift makes only outbound HTTP calls (GitHub API via `gh` CLI, Claude API). No webhook endpoint is implemented.
- **Review delegation to GitHub Actions** — Nightshift posts `@claude review` to trigger a `claude-code-action` workflow in the managed repo. GitHub Actions runs the review and posts the result; Nightshift polls for it and creates a follow-up Task. Nightshift never runs Claude for reviews itself.
- **`review_prompt_template` on Project is kept** — reserved for potential future use (e.g., instructing Claude in the follow-up task about the review context), but is not used by a Nightshift-run Claude review session.
- **Docker-first deployment** — ships as a self-contained image with Claude CLI, gh CLI, and git bundled. Repos are cloned into a persistent `/data` volume on project creation; `repo_path` is auto-managed, not user-supplied.
- **PRReview lifecycle: trigger → receive → follow up** — three-phase state machine managed by `PRSyncWorker`; identity on `[:project_id, :pr_number]` ensures one review workflow per PR regardless of how many poll cycles run.
- **GitHub Actions prerequisite** — each managed repo must have `.github/workflows/claude-review.yml` installed manually before PR review automation works.
- **Nightshift skips reviewing its own PRs** — `trigger_new_reviews/2` filters out any PR whose head branch starts with `nightshift/`. Without this, reviewing a `nightshift/ticket-*` PR would create a follow-up Task → new PR → review → follow-up, looping indefinitely.
- **Follow-up task branch strategy** — the `build_follow_up_description/1` prompt tells Claude the existing PR branch name and lets Claude decide whether to push to it directly or create a new branch. This avoids hard-coding a policy that may not fit all situations.
