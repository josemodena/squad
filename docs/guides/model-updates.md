# Updating role models

Squad 0.6.0 uses Astra for the main PM and architecture roles, and GPT-6.1 Sol
for engineering and engineering review. Sol engineering effort is always medium.
Explicit model overrides remain supported; Administrator settings are unused.

Claude Code keeps `fable` and `opus` aliases for Fable 5.1 and Opus 5.5. Provider
mappings can differ. Use Claude Code 2.1.280 or later for the shipped assignments
and verify the native model. See [Anthropic model configuration](https://code.claude.com/docs/en/model-config).

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
do not prove that a native worker or Project Manager is idle.

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
5. For a managed Codex Project Manager, verify its turn is idle and all child work
   is reconciled, then use `squad session rollover`. This archives its session
   record so the next authorised recovery starts with the configured model.
   An active turn refuses rollover. For interactive sessions, start a new session
   explicitly selecting the new Project Manager model and load the updated skill.
6. Run `squad models` again. Verify the actual model reported by each native
   worker at launch; do not silently accept a fallback or change model mid-job.
   Resume only work already authorised under the project's existing pause policy.

A catalogue suggestion is information, not permission to increase spending or
change a project's model policy. No automatic upgrade service is installed.

## GPT-6.1 Sol

The Engineer and Engineering Reviewer defaults are `gpt-6.1-sol`. Planning and
architecture retain Astra, and the Claude model assignments retain their existing
aliases. Existing project model overrides and recorded jobs keep their values.
If you explicitly pinned either engineering role to `gpt-6-sol`, update that key
when starting new work; do not rewrite the model on an existing job.

The official identifier is documented in the
[OpenAI model reference](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
and was present in the local Codex catalogue on 2026-09-30. Catalogue presence
alone does not demonstrate successful inference. The catalogue did not advertise
an upgrade from the old Sol identifier, so `models --check-upgrades` can correctly
report no advertised upgrade even when the new model is listed separately.

Squad explicitly requires `medium` for Sol engineering roles instead of inheriting
the native catalogue's `low` default. Claims persist the requirement; bind rejects
an absent or conflicting actual effort. Existing jobs keep their recorded effort.
Use `squad models --details` to inspect the effective configuration.
