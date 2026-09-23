# Squad

**Turn a backlog into a coordinated team of coding agents.**

Squad is a pair of plugins for **Codex** and **Claude Code**. It adds a repeatable
way to plan work, assign it to suitable models, review the results, and continue
safely when a session or subscription window ends.

Coding agents can already write code and delegate tasks. The work around them
still takes attention: deciding what is ready, keeping dependencies current,
starting reviews promptly, remembering unfinished work, and preventing two agents
from taking the same task. Squad makes those responsibilities explicit and backs
them with a GitHub Project board and deterministic commands.

For example, when one Engineer finishes while another is still working, the
Administrator can dispatch the finished task to an independent Reviewer
immediately. If capacity runs out, saved job records and checkpoints tell the next
session what to inspect before continuing. The board remains the shared account
of what was agreed and what is left.

Squad aims to reduce coordination time and avoidable idle time while assigning
expensive reasoning to work that needs it. **It does not increase provider limits,
guarantee lower costs, or replace your decisions about scope.**

[Get started](docs/getting-started/quickstart.md) ·
[Documentation](docs/README.md) · [Releases](https://github.com/josemodena/squad/releases) ·
[Contribute](CONTRIBUTING.md) ·
[Report a problem](https://github.com/josemodena/squad/issues/new/choose)

## When Squad helps

- You have several related tasks, dependencies and review stages to coordinate.
- You want one delivery method across Codex and Claude Code, with implementations
  that use each harness's native capabilities.
- You want durable progress records across sessions and subscription resets.
- You want to route planning, architecture, engineering and review to different
  model tiers, with explicit human control over spending policy and pauses.

For a short, isolated change, an ordinary coding-agent session may be all you
need. Squad introduces a board, configuration and a review process; those costs
make more sense for ongoing projects.

## How it works

1. **You and the Project Manager** agree the outcome, priorities and dependencies.
2. **The Administrator** claims eligible work and starts native role subagents.
3. **Architects and Engineers** produce designs and tested changes; separate
   **Reviewers** assess them. Existing approved designs can go straight to coding.
4. **The Administrator** processes each result, updates tracking and merges only
   the reviewed commit through the guarded merge command.
5. **The optional conductor** wakes an unavailable Administrator when recovery is
   needed and capacity is available. Normal subagent completion uses native
   notifications. A user pause always takes precedence.

GitHub stores the plan and delivery status. Local durable records store execution
ownership, worker identities, checkpoints and unhandled results. See the
[workflow guide](docs/guides/workflow.md) for responsibilities and failure cases.

For planning and retrospectives, Squad can open a separate Zellij tab with the
Project Manager and its configured model. You talk directly while the Administrator
coordinates agreed work. See [direct meetings](docs/guides/meetings.md).

## Who makes decisions?

You agree the outcome with the Project Manager. The Administrator keeps delivery
moving between roles. If progress stops, it assigns the problem to the PM, who
resolves it within the agreed scope and authority. Only the PM brings decisions
to you, with a clear explanation and recommendation.

When you answer a request on its GitHub issue, the optional recovery service
can detect your reply while agents are stopped. The PM checks what you authorised
before work resumes. A reply does not override a separate project pause.

Every role has a [job description](docs/roles/README.md). New agents receive the
role instructions, delegation policy and relevant reviewed project decisions and
lessons. Read [decisions, stalled work and learning](docs/guides/decisions-and-learning.md)
for the complete process and setup.

## Working with specifications

Squad complements Spec-Driven Development: an agreed specification supplies the
reference for planning, implementation and independent acceptance. Squad organises
the delivery and handoffs around it. See the
[Spec-Driven Development guide](docs/guides/spec-driven-development.md).

## Recovery and backups

Squad checkpoints unfinished agent work and keeps local, Git-versioned backups of
GitHub Project metadata. Those backups preserve fields, option identities, item
values and supported view configuration, isolated by project. Before migrating or
repairing a board, read [board backup and recovery](docs/guides/board-backup.md).
Keep durable runtime and learning records in your own private backup as well.

## Features and support

**Shared** means both plugins ship the feature. **Role workflow** means agents
must follow the supplied skills; it is not enforced by the harness itself.
**Optional** means additional setup is needed. Automated checks use isolated
fixtures; [live acceptance scenarios](docs/development/acceptance.md) remain
necessary for a particular harness/account combination.

| Feature | Codex | Claude Code |
| --- | --- | --- |
| Native plugin install and namespaced skills | Yes | Yes |
| Shared role descriptions, delegation and startup context | Yes | Yes |
| PM-owned resolution and user escalation | Shared workflow and request provenance checks | Shared workflow and request provenance checks |
| GitHub reply observation while agents are stopped | Optional conductor; bounded observer cadence | Optional conductor; ten-minute timer |
| Private, versioned decisions and PM-reviewed lessons | Shared CLI | Shared CLI |
| Six roles with configurable model assignments | Yes | Yes; also ships agent definitions |
| Read-only model upgrade discovery | Catalogue suggestions via `models --check-upgrades` | No automatic discovery; native alias verification |
| Planning, sprint review, forecasts and retrospectives | Shared role workflow | Shared role workflow |
| Owned blockers and continuation | Visible user requests, PM repairs, guarded claims | Visible user requests, PM repairs, guarded claims |
| Direct Project Manager conversations | New Zellij tab; explicit model/effort | New Zellij tab; explicit model/effort |
| Conditional architecture and separate design review | Shared role workflow | Shared role workflow |
| Test-driven engineering and separate code review | Shared role workflow | Shared role workflow |
| Parallel native subagents | Yes; within harness limits | Yes; within harness limits |
| Completion delivered to the coordinating agent | Native notifications | Native background-agent notifications |
| Dispatch ready work without waiting for an unrelated batch | Administrator workflow | Administrator workflow |
| Shared board reads and fresh per-task claims | Yes | Yes |
| Grouped, backed-up field handoffs | Yes | Yes |
| Shared local API cooldowns and usage counters | Yes | Yes |
| GitHub Issues and Projects tracking | Shared CLI | Shared CLI |
| Task prerequisites using native blocked-by relationships | Shared CLI | Shared CLI |
| Responsible role, stage, agreement and design status | Shared Project fields | Shared Project fields |
| Priority, Needed by, forecast and estimates | Shared Project fields | Shared Project fields |
| Atomic job claims and duplicate-assignment protection | Shared local runtime | Shared local runtime |
| Record actual worker and model identity | Yes; native thread/turn metadata too | Yes; native worker identity |
| Save tracked patch, untracked files, next step and test evidence | Shared checkpoint command | Shared checkpoint command |
| Durable background-command logs and exit status | Shared CLI | Shared CLI |
| Recover unfinished work and acknowledge handled results | Shared CLI | Shared CLI |
| Review exact PR head against current main | Shared CLI | Shared CLI |
| Guard merge against changes after review | Shared merge command | Shared merge command |
| Persist human pause and quota-policy overrides | Shared runtime | Shared runtime |
| Fresh subscription-usage reading | App Server rate-limit refresh | **External usage collector required** |
| Handle short and weekly provider windows | Reads provider windows | Depends on fields supplied by collector |
| Resume after capacity reset | Optional systemd/App Server recovery | Optional systemd/Zellij recovery; fresh collector data required |
| External recovery check interval | 30 seconds | 10 minutes |
| Managed Administrator session inspect/attach/rollover | App Server gateway | No equivalent gateway; terminal adapter |
| Reconcile ended native workers automatically | Exact Codex thread/turn records | Native inspection required before replacement |
| Recovery services for multiple projects | Per-project systemd instances | One legacy conductor per OS user |
| Idle-time and dispatch-delay measurements | Shared recorded observations | Shared recorded observations |
| Model-free CLI for routine GitHub operations | Yes | Yes |
| Local Git-versioned board backups, isolated per project | Yes | Yes |
| Confirmed board restore with diff and interruption journal | Supported API fields/views; see limits | Supported API fields/views; see limits |
| Linux | Supported runtime target | Supported runtime target |
| macOS / native Windows | Not supported or validated | Not supported or validated |
| Windows with WSL2 | Untested Linux route; systemd needed for recovery | Untested Linux route; systemd needed for recovery |

These controls apply when using Squad's commands. They do not prevent a user or
agent from bypassing them with direct GitHub or shell operations. Protect the
repository's default branch separately if server-side enforcement is required.

Routine board reads are shared locally, and each claim checks its selected task
again before work starts. Grouped handoffs reduce backup reads; shared API
cooldowns prevent local workers from repeatedly retrying an exhausted budget.
These features work with free GitHub accounts. See
[GitHub API usage](docs/guides/github-api.md) for commands and limits.

## Requirements

- **Linux**, Bash 4+, Python 3.10+, Git, GitHub CLI 2.46.0+ (`gh`), `jq`, GNU coreutils,
  `curl`, and `flock` (usually in `util-linux`).
- **One harness:** Codex or Claude Code, installed and authenticated, with plugin
  and native subagent support. The development baseline is Codex 0.155.1 and
  Claude Code 2.1.280; these are CLI-check baselines, not universal minimums.
  **Opus 5.5 specifically requires Claude Code 2.1.280 or later.**
- A GitHub repository and a **GitHub Project v2**, with permission to manage its
  issues, pull requests and fields. Setup can create a board.
- Access to the models you configure. The default aliases below may not be
  available to every account; select supported models during setup.
- Durable local storage for worktrees and runtime state, unique to each project.
- **Direct planning/retro tabs:** Zellij with initial-command support for `action new-tab` (tested on 0.44.3).
- **Optional recovery:** systemd user services; Go 1.23+ for Codex, or Zellij for
  Claude Code. Claude capacity-aware dispatch also needs a usage collector,
  which Squad does not bundle.

See [requirements and permissions](docs/getting-started/requirements.md), including
GitHub authentication and the limits of platform support.

## Install

Choose one harness. This installs its plugin and the short `squad` command from a
local checkout; it does not start agents, configure a project or enable a timer.

```bash
git clone https://github.com/josemodena/squad.git
cd squad
./install.sh codex                 # or: ./install.sh claude-code
export PATH="$HOME/.local/bin:$PATH"
squad --harness codex doctor       # or: --harness claude-code
```

Keep the checkout: the command and local marketplace use it. Installing both is
supported; select `--harness` when a project has settings for both.

Prefer the native marketplace commands without a checkout? See
[installation, updates and removal](docs/getting-started/installation.md).

## Start your first project

1. Authenticate GitHub with `gh auth login`, and grant Projects access with
   `gh auth refresh -s project`. Change into the repository you want Squad to work on.
2. Start a fresh Codex or Claude Code session. Invoke **`$squad:init` in Codex** or
   **`/squad:init` in Claude Code**. Agree the board, model assignments, storage,
   quota policy and repository setup. Setup writes a local configuration and
   provisions tracking; it does not invent a product plan.
3. Invoke **`$squad:project-manager`** or **`/squad:project-manager`**. Start with one
   small issue and explicit acceptance criteria. Agree the plan and review needs.
4. Verify capacity with `squad quota`, then inspect `squad ready`. Missing usage,
   unapproved work and unmet prerequisites are reported as blockers.
5. Start **`$squad:administrator`** or **`/squad:administrator`** to execute the
   agreed work. The main session must use your configured Administrator model;
   selecting a skill alone does not switch the model.
6. Inspect progress with `squad board` and `squad status`. Run one complete
   implement/review cycle before considering unattended recovery.

The [step-by-step tutorial](docs/getting-started/quickstart.md) includes prompts,
expected results, pause/resume and the optional recovery setup.

## Everyday commands

```bash
squad board
squad ready
squad status
squad models
squad pause --reason "Review priorities before continuing"
squad policy --mode unrestricted --reason "User waived voluntary pacing"
squad --harness codex session inspect
```

`unrestricted` waives Squad's voluntary pacing, not provider limits or a user
pause. Commands detect the project configuration. Use `--project /path/to/repo`
when working elsewhere. See the [CLI reference](docs/reference/cli.md).

## Default role models

| Role | Codex | Claude Code |
| --- | --- | --- |
| Administrator | GPT-6-Luna (`gpt-6-luna`) | Sonnet 5 (`sonnet`) |
| Project Manager | GPT-6-Astra (`gpt-6-astra`) | Fable 5.1 (`fable`) |
| Architect | GPT-6-Astra (`gpt-6-astra`) | Fable 5.1 (`fable`) |
| Engineer | GPT-6-Sol (`gpt-6-sol`) | Opus 5.5 (`opus`) |
| Architecture Reviewer | GPT-6-Astra (`gpt-6-astra`) | Fable 5.1 (`fable`) |
| Engineering Reviewer | GPT-6-Sol (`gpt-6-sol`) | Opus 5.5 (`opus`) |

These are configurable assignments, not a claim of universal model availability
or a price ranking. Claude aliases can vary by provider or override; the versions
above describe the Anthropic defaults verified on 2026-09-22. Opus 5.5 requires
Claude Code 2.1.280 or later.

Run `squad models --check-upgrades` to check Codex catalogue upgrade suggestions
without changing settings or running agents. See [model updates](docs/guides/model-updates.md)
for safe upgrades and [configuration](docs/reference/configuration.md) for overrides.

## Project status and contributing

Squad is early-stage software. Deterministic runtime, packaging, CLI and recovery
adapter tests run in CI. Live notification delivery and real subscription resets
still depend on the installed harness and account; fixture tests cannot prove
those end-to-end behaviours. See [known limitations](docs/reference/limitations.md).

The repository separates the two distributable plugins and their shared sources:

```text
plugins/codex/squad/        Codex plugin, hooks and App Server adapter
plugins/claude-code/squad/  Claude Code plugin, agents and terminal adapter
shared/runtime/            Canonical deterministic runtime and tests
bin/squad                  Human-friendly command entry point
docs/                      Tutorials, guides, reference and maintainer docs
tools/                     Packaging, validation and publication helpers
tests/                     CLI and repository-level checks
```

Contributions that improve portability, reliable recovery, documentation and
measured delivery outcomes are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md)
and the [roadmap](docs/development/roadmap.md). Report sensitive findings through
[SECURITY.md](SECURITY.md).

## Licence

Squad’s original code and documentation are open source under the
[Apache License 2.0](LICENSE). See [licensing](docs/development/licensing.md)
for contribution terms and third-party components.
Squad is an independent community project, not an official OpenAI or Anthropic product.
