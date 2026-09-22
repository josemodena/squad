---
repository: OWNER/NAME
project_owner: OWNER
project_owner_type: user
project_number: 0
origin_remote: git@github.com:OWNER/NAME.git
mirror_remote:
ssh_key:
scratch_root: ~/.local/state/squad/OWNER/NAME
sprint_day: Saturday
sprint_hour_utc: 17
quota_daily_percent: 14
quota_weekly_cap_percent: 85
quota_command: claude-quota
usage_command: claude-usage
transcripts_dir: ~/.claude/projects
memory_store:
harness_changelog_url: https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md
harness_version_file:
harness_watchlist:
decider: THE DECIDER
decider_label: action-for-decider
administrator: Administrator
administrator_model: sonnet
project_manager_model: fable
architect_model: fable
engineer_model: opus
architecture_reviewer_model: fable
engineering_reviewer_model: opus
max_workers: 3
continuation_mode: native
quota_mode: pacing
conductor_session: claude
conductor_command: claude
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

These settings support the retrospective's two reports. `transcripts_dir`
and `memory_store` are what `housekeeping.sh` measures. `harness_version_file`
and `harness_watchlist` name two files this project keeps: one holding the
version of the tools last reviewed, one holding the terms worth reading about.
Create them, name them here, and `changelog-review.sh` runs with no arguments.

The body of this file is for people. Use it for anything about how this project
runs that does not fit a setting.
