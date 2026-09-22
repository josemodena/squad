# Requirements and permissions

## Supported environment

Linux is the runtime target. Scripts use GNU `date -d`, GNU filesystem utilities,
Bash and `flock`; the Python runtime imports Unix `fcntl`. Copying the skills to
another platform does not establish support for the complete workflow.

| Component | Required for |
| --- | --- |
| Bash 4+, Python 3.10+ (standard library) | CLI, settings, durable runtime |
| Git, GitHub CLI 2.46.0+, jq | Repository, Issues and Project operations |
| GNU coreutils, util-linux (`flock`), curl | Shell helpers and release review |
| Codex or Claude Code, authenticated | Model work, plugins, native subagents |
| GitHub repository and Project v2 | Shared planning and tracking |
| Writable durable local storage | Worktrees, job records, logs, checkpoints |
| systemd user manager | Optional unattended recovery |
| Go 1.23+ | Build Codex's optional App Server controller |
| Zellij | Claude Code's optional terminal recovery |
| Claude usage collector | Fresh quota data for Claude capacity-aware dispatch |

GitHub CLI 2.46.0 is the supported minimum, including paginated REST operations.
`doctor` checks its version; board access still needs a live permission check.

Development baselines: Codex 0.155.1, Claude Code 2.1.280. These versions were used
for CLI and manifest checks; they are not established minimum versions. Harness
interfaces can change. Verify a complete delivery cycle after a harness upgrade.

The current Claude defaults need Claude Code **2.1.280 or later** for Opus 5.5.
Sonnet 5 needs 2.1.197 and Fable 5.1 needs 2.1.257. Run `claude --version` and
`claude update` if needed. Provider mappings and overrides can differ; see
[model versions and safe upgrades](../guides/model-updates.md).

macOS and native Windows are not supported. WSL2 may provide the required Linux
environment, but is untested; recovery also needs a functioning user systemd
manager. Containers without systemd can run interactive coordination, but not the
supplied recovery services. Network filesystems and distributed runtime locks are
not tested; keep runtime storage local to one coordination host.

On Debian/Ubuntu, install the base utilities using your package manager:

```bash
sudo apt-get update
sudo apt-get install bash python3 git jq coreutils util-linux curl
```

Install GitHub CLI and your chosen harness using their own installation guides.
`install.sh` does not install system packages or use sudo. Check the result with
`squad --harness codex doctor` or `squad --harness claude-code doctor`.

## Authentication and access

```bash
gh auth login
gh auth refresh -s project
gh auth status
```

The GitHub identity must be able to read/write the target repository's issues and
pull requests and manage the chosen Project's fields and items. Organisation
policies can require additional approval. Verify board access with `squad board`;
a successful login alone does not prove project permissions. Git pushes also need
working authentication. Record the actual origin URL in project settings.

Use the harness's own sign-in process. Squad does not provide a model subscription,
API key, token broker or additional quota. Model access and native delegation
capabilities depend on the account. Confirm the six configured model names during
setup rather than assuming that the defaults are universally available.

## Storage and permissions

Use a distinct `scratch_root` for each project, for example
`~/.local/state/squad/example/demo`. Both harnesses may share that directory for
the same project so their ownership records can prevent duplicate work. Do not
share it between unrelated projects or independent coordination hosts.

Keep local settings, transcripts, usage readings and checkpoints out of Git.
Checkpoints can contain source code and untracked files. Treat their storage as
sensitive; they are recovery material, not an off-machine backup. Do not delete
worktrees while jobs or background commands are still running.

Squad scripts run with your OS/GitHub permissions. Plugin installation and hooks
follow the harness's trust controls. The CLI's review gates apply to its merge
command; GitHub branch rules provide separate server-side enforcement.
