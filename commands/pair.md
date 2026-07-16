---
description: Attach THIS session to a live-bus task so two concurrent sessions share memory on the spot ("same brain, two hands"). Usage — /pair <task-id>. Both sessions run it with the SAME task-id. Findings and lane-claims written via /bus surface in the other session at its next turn.
argument-hint: "<task-id>   (a short shared slug both sessions agree on, e.g. `owner-reconcile` or `auth-sweep`)"
---

# /pair — attach to a live-bus task

Goal: two Claude Code sessions cooperate on ONE task, sharing findings + coordinating lanes live
(turn-boundary, not true real-time — that's the harness ceiling). Code stays isolated (use worktrees);
only MEMORY is shared, via files outside either tree.

## Steps
1. Read `$ARGUMENTS` as `<task-id>`. If empty, ask for one (a short slug both sessions will type).
2. Use this session's REAL `session_id` — injected at session start as a line
   `LIVE-BUS: this session's session_id is <sid>`. This is mandatory: the read-hook keys off the real
   session_id, so a guessed value fails silently. If that line isn't in context, stop and tell the user
   to restart the session (the `session-id-inject` SessionStart hook must run) — never guess an id.
   Then run this PowerShell to attach (creates the task dir, writes the reverse-pointer the read-hook
   uses, appends a `join` line):

   ```powershell
   $task = "<task-id>"; $sid = "<real-session-id-from-the-LIVE-BUS-line>"
   $bus = "$env:USERPROFILE\.claude\live-bus"; $td = "$bus\$task"
   New-Item -ItemType Directory -Force -Path $td, "$bus\_sessions" | Out-Null
   Set-Content "$bus\_sessions\$sid" $task -NoNewline
   $ts = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
   ('{"session":"'+$sid+'","ts":'+$ts+',"kind":"join","text":"attached to '+$task+'","tier":"promoted"}') | Add-Content "$td\bus.$sid.jsonl"
   ```
3. Tell the user: "Paired to task `<task-id>`. Run `/pair <task-id>` in the OTHER session with the
   same id. Use `/bus finding|claim|done <text>` to share; the other hand sees it at its next turn."
4. Recommend worktrees if both sessions are in the same repo (code isolation).

## Notes
- Silent for solo sessions: the read-hook exits instantly unless a session is paired.
- `/bus` writes; `/unpair` detaches. The bus is ephemeral per task — delete `~/.claude/live-bus/<task>`
  when done.
- Delivery is at-most-once notification: the watermark advances when the hook reads, so a canceled prompt can drop the injection. The JSONL files stay the durable truth — re-read them manually if in doubt.
- Claims have no TTL: a `claim` stands until a `done`/`leave` or the task dir is purged. If a hand crashes mid-claim, clear it by hand.
- Provisional vs promoted: a `finding` defaults to provisional (unverified). Only mark `tier:promoted`
  after a real check — never rubber-stamp, or the shared-truth guarantee is theater.
