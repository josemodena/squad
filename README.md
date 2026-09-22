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

## Features and support

**Shared** means both plugins ship the feature. **Role workflow** means agents
must follow the supplied skills; it is not enforced by the harness itself.
**Optional** means additional setup is needed. Automated checks use isolated
fixtures; [live acceptance scenarios](docs/development/acceptance.md) remain
necessary for a particular harness/account combination.

| Feature | Codex | Claude Code |
| --- | --- | --- |
| Native plugin install and namespaced skills | Yes | Yes |
| Six roles with configurable model assignments | Yes | Yes; also ships agent definitions |
| Planning, sprint review, forecasts and retrospectives | Shared role workflow | Shared role workflow |
| Direct Project Manager conversations | New Zellij tab; explicit model/effort | New Zellij tab; explicit model/effort |
| Conditional architecture and separate design review | Shared role workflow | Shared role workflow |
| Test-driven engineering and separate code review | Shared role workflow | Shared role workflow |
| Parallel native subagents | Yes; within harness limits | Yes; within harness limits |
| Completion delivered to the coordinating agent | Native notifications | Native background-agent notifications |
| Dispatch ready work without waiting for an unrelated batch | Administrator workflow | Administrator workflow |
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

## Requirements

- **Linux**, Bash 4+, Python 3.10+, Git, GitHub CLI 2.46.0+ (`gh`), `jq`, GNU coreutils,
  `curl`, and `flock` (usually in `util-linux`).
- **One harness:** Codex or Claude Code, installed and authenticated, with plugin
  and native subagent support. The development baseline is Codex 0.155.1 and
  Claude Code 2.1.278; these are tested CLI versions, not proven minimum versions.
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
| Administrator | Luna (`gpt-5.6-luna`) | Sonnet (`sonnet`) |
| Project Manager | Astra (`gpt-6-astra`) | Fable (`fable`) |
| Architect | Astra (`gpt-6-astra`) | Fable (`fable`) |
| Engineer | Sol (`gpt-5.6-sol`) | Opus (`opus`) |
| Architecture Reviewer | Astra (`gpt-6-astra`) | Fable (`fable`) |
| Engineering Reviewer | Sol (`gpt-5.6-sol`) | Opus (`opus`) |

These are configurable assignments, not a claim of universal model availability
or a price ranking. See [configuration](docs/reference/configuration.md).

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

Use an agreed specification to drive delivery with the
[Spec-Driven Development guide](docs/guides/spec-driven-development.md).

Before migrating or repairing a board, read the
[board backup and recovery guide](docs/guides/board-backup.md).
