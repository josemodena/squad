# Updating role models

Squad 0.4.6 defaults to GPT-6-Luna for administration, GPT-6-Sol for engineering
and engineering review, and GPT-6-Astra for planning and architecture. Explicit
project settings and environment overrides still take precedence.

Claude Code keeps `sonnet`, `fable` and `opus` aliases. As verified on 2026-09-22,
Anthropic's documented defaults are Sonnet 5, Fable 5.1 and Opus 5.5. Other
providers, gateways and `ANTHROPIC_DEFAULT_*_MODEL` overrides can resolve them
differently. Opus 5.5 needs Claude Code 2.1.280 or later; Fable 5.1 needs 2.1.257;
Sonnet 5 needs 2.1.197. Use `claude --version` and, if necessary, `claude update`.
Verify the native session's actual model rather than assuming an alias proves
access. See [Anthropic model configuration](https://code.claude.com/docs/en/model-config).

## Check for upgrades

From a configured project:

```sh
squad models
squad models --check-upgrades
```

The first command keeps its existing role-to-model JSON output. The second calls
`codex debug models` once, with a 30-second timeout, and reports each configured
model's advertised upgrade. It never guesses the next version from its name,
launches a model, writes project/runtime settings, or changes a job. It includes
unfinished jobs so their recorded models remain visible. Runtime records alone
do not prove that a native worker or Administrator is idle.

The report distinguishes `upgrade-suggested`, `no-upgrade-advertised` and
`not-in-catalogue`. A suggested model missing from the catalogue is flagged;
none of these states is proof of account access or pricing. Codex can serve a
cached catalogue: the report timestamp is when Squad checked, not a claim that
the provider refreshed its catalogue. Failed or malformed reads return an error,
not an invented replacement. Claude returns `unsupported` for automatic discovery
and keeps aliases explicitly unverified.

## Apply at a safe boundary

1. Inspect `squad recover`, native workers and, for managed Codex coordination,
   `squad session inspect`. Let active work finish or checkpoint and reconcile it.
   Do not interrupt a worker simply to upgrade its model.
2. Before updating the plugin, keep explicit old role-model settings in any
   project that must continue on its existing models. Defaults can change with
   a Squad release; project overrides are never rewritten by the upgrade check.
3. Update Squad and the harness. Change only the intended role-model keys in
   `.codex/squad.local.md` or `.claude/squad.local.md` when the boundary is safe.
   Preserve unrelated settings, quota policy, runtime state and user pauses.
4. Existing jobs must continue with their recorded model, even if the role's new
   default differs. `squad bind` checks against that recorded model and stores
   `actual_model`; it does not rewrite historical jobs to the new default.
5. For a managed Codex Administrator, verify its turn is idle and all child work
   is reconciled, then use `squad session rollover`. This archives its session
   record so the next authorised recovery starts with the configured model.
   An active turn refuses rollover. For interactive sessions, start a new session
   explicitly selecting the new Administrator model and load the updated skill.
6. Run `squad models` again. Verify the actual model reported by each native
   worker at launch; do not silently accept a fallback or change model mid-job.
   Resume only work already authorised under the project's existing pause policy.

A catalogue suggestion is information, not permission to increase spending or
change a project's model policy. No automatic upgrade service is installed.
