# Release process

Stable Squad releases are published through
[GitHub Releases](https://github.com/josemodena/squad/releases). A `vMAJOR.MINOR.PATCH`
tag triggers the release workflow. Earlier changelog entries record development
versions; 0.4.2 is the first GitHub release.

## Prepare and validate

1. Choose the next version. Update VERSION, plugin manifests, Claude marketplace
   version and CHANGELOG.md. Codex native/portable versions must agree; the Codex
   cache suffix is permitted, but the base must equal VERSION.
2. Add `docs/releases/VERSION.md` with changes, installation/update instructions,
   migration needs, validation evidence and known limits. Use absolute repository
   links because the same Markdown becomes the GitHub release body.
3. Run `python3 tools/sync-package.py`. Each plugin must include its runtime
   reference, licence and notices. Run `bash tools/test.sh` and validate changed
   manifests with the harness. Run appropriate live tests for changed native
   behaviour; distinguish fixture coverage from a real model delivery cycle.
4. Inspect the committed file list for private data and credentials. Do not include
   runtime records, cold-test logs or private operational documents in artifacts.
5. Open a PR, resolve review findings and wait for required CI. Merge the exact
   tested head through the protected main branch.

## Tag and publish

From a clean checkout of the merged main commit:

```bash
git switch main
git pull --ff-only
VERSION=$(cat VERSION)
git tag -a "v$VERSION" -m "Squad $VERSION"
git push origin "v$VERSION"
```

The [release workflow](../../.github/workflows/release.yml) runs the full CI suite,
checks that the tag matches VERSION and its commit belongs to main, and packages
committed source only. A separate publishing job gets repository contents-write
permission. It publishes:

- `squad-VERSION-source.tar.gz`: complete checkout with installer and short CLI.
- `squad-VERSION-codex.tar.gz`: self-contained Codex plugin.
- `squad-VERSION-claude-code.tar.gz`: self-contained Claude Code plugin.
- `SHA256SUMS`: checksums for those three archives.

GitHub additionally provides its standard source downloads. No prebuilt controller
binaries are distributed. Plugin-only archives do not include the top-level CLI.

## Verify and recover

Watch the Release workflow and inspect the published tag, notes and assets:

```bash
gh run list --workflow release.yml
gh release view "v$VERSION"
mkdir -p /path/to/empty-release-check
cd /path/to/empty-release-check
gh release download "v$VERSION" --repo josemodena/squad
sha256sum -c SHA256SUMS
```

Verify an extracted source installation and the packaged manifests. Marketplace
installs following main may receive newer commits than a release; use a tagged
source checkout when a fixed version is required. Keep the CLI checkout aligned
with the installed plugin.

If validation fails, no release is published. Fix via a reviewed PR and create a
new patch tag; do not move an existing published tag. If publication fails after
creating a release, inspect the existing assets before retrying. The workflow
refuses to overwrite an existing release automatically. Complete a partial upload
only after verifying it against the same tag; otherwise publish a corrected patch
version. Never relabel an untested commit as a tested release.
