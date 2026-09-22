---
repository: OWNER/NAME
project_owner: OWNER
project_owner_type: user
project_number: 0
origin_remote: git@github.com:OWNER/NAME.git
mirror_remote:
ssh_key:
scratch_root: ~/.cache/squad/OWNER-NAME
sprint_day: Saturday
sprint_hour_utc: 17
quota_daily_percent: 14
quota_weekly_cap_percent: 85
quota_command: codex-quota
transcripts_dir: ~/.codex/sessions
memory_store:
harness_name: Codex
harness_repository: openai/codex
harness_changelog_url: https://raw.githubusercontent.com/openai/codex/main/CHANGELOG.md
harness_version:
harness_version_file:
harness_watchlist:
decider: THE DECIDER
decider_label: action-for-decider
administrator: Administrator
administrator_model: gpt-5.6-luna
project_manager_model: gpt-6-astra
architect_model: gpt-6-astra
engineer_model: gpt-5.6-sol
architecture_reviewer_model: gpt-6-astra
engineering_reviewer_model: gpt-5.6-sol
max_workers: 3
continuation_mode: native
quota_mode: pacing
conductor_session: codex
conductor_command: codex
tracks:
  - TRACK ONE
  - TRACK TWO
owners:
  - THE DECIDER
  - Administrator
  - Engineer
statuses:
  - Backlog
  - This sprint
  - In progress
  - In review
  - Blocked
  - Done
---

# Squad settings for this project

The front matter above is the whole configuration. Every Squad script reads it;
nothing in the plugin knows this project's name, people, models or repository
any other way.

Put nothing secret here. Credentials belong in the tools that hold them, never
in a file an agent reads.

The retrospective uses `transcripts_dir` and `memory_store` for housekeeping.
`harness_version` or `harness_version_file` records the last release reviewed.
`harness_changelog_url` selects the source, and the optional
`harness_watchlist` limits the entries printed.

The body of this file is for people. Use it for anything about how this project
runs that does not fit a setting.
