---
name: operate
description: Compatibility entry for the main Squad Project Manager session. Launches the correctly configured PM; does not assume or change the current model.
---

# Start the Project Manager

The Administrator role was removed in 0.6.0. Run
`bash ${PLUGIN_ROOT}/scripts/start.sh delivery` and report the returned tab and
model. If already in the verified main PM session, use the project-manager skill.
Do not impersonate the PM on the current model or start a second coordinator.
Inspect the actual environment if launch fails and give its exact remedy.
