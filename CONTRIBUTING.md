# Contributing to Squad

Start with a reproducible issue or a short proposal explaining the problem and
expected behaviour. Small fixes and documentation corrections can go straight to
a pull request. Discuss changes to state ownership, dispatch, review gates or
provider integrations before undertaking a large implementation.

## Local development

Use Linux with Python 3.10+, Bash, Git, jq, GitHub CLI, GNU utilities and Go 1.23+.
The fixture suites do not need GitHub credentials or paid model calls.

```bash
git clone https://github.com/josemodena/squad.git
cd squad
python3 tools/sync-package.py
bash tools/test.sh
```

Edit shared runtime code in `shared/runtime/`, then run the sync command. Each
plugin contains a generated copy so it works when installed alone. Edit canonical
runtime documentation in `docs/reference/runtime.md`; that reference is also
copied into both packages. Do not edit generated copies independently.

Harness-specific code stays under `plugins/codex/squad/` or
`plugins/claude-code/squad/`. Use `bin/squad --harness ... doctor --offline` while
checking a checkout. See [architecture](docs/development/architecture.md) for the
boundaries and [acceptance scenarios](docs/development/acceptance.md) for live work.

## Pull requests

- Explain the user-visible problem and resulting behaviour.
- Include meaningful tests for changed coordination, persistence or recovery
  behaviour. Documentation-only changes need link/packaging checks.
- State what was tested and what still requires a real harness/account.
- Update relevant documentation and the Unreleased changelog.
- Keep example projects, names, paths and credentials generic. Never commit real
  runtime state, transcripts, quota readings or local settings.
- Keep commits focused. Do not modify a user's pause, live board or running
  services as a side effect of testing.

AI-assisted contributions are welcome. Contributors remain responsible for
reviewing generated code, verifying tests and having the right to submit the
material. Do not claim that fixture tests prove actual provider behaviour.

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security-sensitive issues
through [SECURITY.md](SECURITY.md), not a public issue. Maintainers make release
and scope decisions; issues and pull requests are the normal discussion record.
There is no response-time commitment or paid support contract.

The project licence decision is pending; no contributor licence agreement is
requested. The contribution policy will follow the selected project licence.
