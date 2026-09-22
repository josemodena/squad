---
name: quota
description: Read Squad capacity and effective policy, persist an authorised quota override, or explain why work cannot launch.
---

# Capacity and policy

Run the harness quota command and `squad.sh policy`. Three independent conditions
exist: user pause, voluntary Squad pacing, and actual provider exhaustion.

Persist the user's instruction immediately with `squad.sh policy --mode MODE
--reason TEXT [--until EPOCH]`. Modes are pacing, weekly (weekly cap only), and
unrestricted (disregard voluntary pacing and cap). Read it back. An unrestricted
policy still cannot manufacture provider capacity or override a deliberate pause.
Use `squad.sh pause/resume --reason TEXT` only for an explicit user pause/resume;
a subscription reset never resumes a user-paused project.

Fresh readings and provider limits still apply. Record start/checkpoint/finish
readings where supported. Overlapping account use is shared; do not sum it as
independent per-task cost. On provider exhaustion checkpoint what is possible and
let the external conductor verify availability after reset. The next model request
may fail before a final report; execution records must already be durable.
