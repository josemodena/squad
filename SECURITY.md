# Security policy

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/josemodena/squad/security/advisories/new)
for a suspected vulnerability. Include affected version, harness, platform,
reproduction steps and expected/actual behaviour. Redact credentials, personal
information and unrelated project data. Do not attach real checkpoints or agent
transcripts unless a maintainer has established a suitable private channel.

If private reporting is unavailable, open a public issue requesting a private
contact route without disclosing the vulnerability. Do not rely on a guaranteed
response time; this is a community-maintained project.

## Supported versions

Security fixes target the latest release and the main branch. Older releases do
not have a separate maintenance commitment. Review the changelog before updating
and preserve live job state and deliberate pauses during migration.

## Boundaries

Squad executes local scripts and uses the permissions of your harness, OS user and
GitHub identity. It is not a sandbox. Model-generated text and repository content
are untrusted inputs; the harness's permission controls remain essential.

Runtime state, worktrees and checkpoints can contain sensitive source. Keep them
out of public repositories and use appropriate local access controls. The supplied
review gates govern Squad's CLI path, not direct GitHub access. Configure branch
rules if you need independent server-side merge enforcement.

Dependencies are kept small. The Codex controller uses the module versions in
its go.mod/go.sum; updates are reviewed through pull requests. Never publish
credentials or temporary quota data to reproduce an issue.
