# Release and publication process

## Prepare a release

1. Update VERSION, plugin manifests, Claude marketplace version and CHANGELOG.md.
   Codex's native/portable manifests must have the same version. A Codex cache
   suffix is permitted; its base must equal VERSION.
2. Run `python3 tools/sync-package.py`. Both packages must be self-contained,
   including their runtime reference and licence.
3. Run `bash tools/test.sh`, validate the manifests with the installed harnesses,
   and inspect the changed documentation and installation flow.
4. Run the systemd integration test on a suitable Linux host and record live
   acceptance evidence for changed native harness behaviour.
5. Review source for private names/paths and credentials. Pattern checks are
   useful but cannot prove absence. Do not publish test logs or runtime archives.
6. Merge a reviewed change, tag the same commit and write release notes with
   migration instructions. Publish source only until binary dependency notices
   and reproducible build procedures are in place.
7. Test marketplace installation from a clean account/home directory. Document
   the tested CLI versions and any unverified platform assumptions.

## Publish a fresh public snapshot

Use this when a private development repository's history must not become public.
Do not make the old repository public and do not push its branches/tags to the new
one. Renaming a private repository does not remove its history.

After committing and validating the intended snapshot:

```bash
python3 tools/export-public.py /path/to/new-public-checkout
```

The exporter uses `git archive HEAD`; it copies tracked release files only, without
`.git`, ignored files, issues, PR discussions or commit metadata. It refuses a
dirty source tree and an existing destination. Inspect the export, initialise an
independent repository with a generic project author identity, and publish only
its new initial commit. Do not import private issues or PR comments.

Before publishing, apply the owner's selected licence, confirm the intended
repository visibility/name, and inspect the public file list. On GitHub configure
Issues, private vulnerability reporting, dependency updates, Actions and branch
rules. Give the new repository a clear description and topics. Keep the old
repository private and update its local remote so it cannot accidentally push
historical objects into the new public repository.

Verify the public repository has exactly the expected new history, passes CI,
has the correct licence and contains no old branches or tags. GitHub accounts
and third-party dependency metadata are separate from source-file content; never
remove legally required third-party notices to satisfy a cosmetic naming rule.
