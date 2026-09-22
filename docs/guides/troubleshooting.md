# Troubleshooting

| Symptom | Check and next step |
| --- | --- |
| `squad: command not found` | Add the installer's bin directory to PATH; verify the source checkout still exists. |
| No settings / both harnesses configured | Run the init skill or pass `--harness codex` / `--harness claude-code`; use `--project` from another directory. |
| Plugin missing after an update | Refresh the marketplace, reinstall, then start a new harness session. |
| `gh` authenticated but board unreadable | Check Project number, owner type, repository access and Projects scope. |
| Quota `missing` or `stale` | Codex: inspect App Server refresh output. Claude: verify the external collector and timestamps. |
| `ready` excludes an issue | Read its reasons: agreement, design, stage/role, estimate, dependencies, status, pause and headroom are separate gates. |
| Policy override did not resume work | Unrestricted policy does not clear a pause or legacy hold and does not override provider exhaustion. |
| Claimed job has no bound worker | Inspect native workers before retrying; a spawn response may have been lost. |
| Worker ended without a report | Preserve its worktree and processes; inspect `squad recover`, then record reconciliation before replacement. |
| Merge rejected after a passing review | The PR head changed or integration evidence is missing; review the new exact head. |
| Timer installed but nothing starts | Check `--no-enable`, user manager status, printed hold path, fresh capacity, and a real pending recovery event. |
| Codex session model mismatch | Preserve state, wait until idle and use the documented rollover procedure; do not bypass the stored session policy. |

Start with `squad doctor`, `squad quota --json`, `squad status`, and `squad ready`.
Only commands needing GitHub call GitHub. Do not repeatedly query a model to poll
a blocked condition. Preserve the output needed to diagnose it, with secrets and
project-specific material removed before sharing.

## GitHub CLI pagination fails

Squad supports GitHub CLI 2.46.0 and later. If an older Squad installation reports
`unknown flag: --slurp`, update Squad to 0.4.2 or later and run `squad doctor`.
The runtime now reads the successive JSON pages returned by `gh api --paginate`.
Do not hide a failed first run by silently installing a different CLI.

## Tests leave a dirty tree

Inspect `git status --short`. Run Python tests with `PYTHONDONTWRITEBYTECODE=1`
or `python3 -B`, and use appropriate ignore rules for generated test artifacts.
Only remove files you have identified as disposable. The merge guard correctly
rejects unexplained changes; preserve it and retain other workers' files.
