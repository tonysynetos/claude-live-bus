---
description: Detach THIS session from its live-bus task (stops the read-hook from surfacing the other hand's lines). Usage — /unpair. Optionally clean up the task's bus files when both sessions are done.
argument-hint: "(no args; add `--purge` to delete the whole task bus when everyone's done)"
---

# /unpair — detach from the live-bus

## Steps
1. Use this session's REAL `session_id` (injected at session start: `LIVE-BUS: this session's session_id is <sid>`) and read its task at `~/.claude/live-bus/_sessions/<session-id>`. If no pointer, say "not paired" and stop.
2. Append a `leave` line, then remove this session's reverse-pointer + watermark:

   ```powershell
   $sid = "<real-session-id-from-the-LIVE-BUS-line>"; $bus = "$env:USERPROFILE\.claude\live-bus"
   $task = (Get-Content "$bus\_sessions\$sid" -Raw).Trim()
   $ts = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
   ('{"session":"'+$sid+'","ts":'+$ts+',"kind":"leave","text":"detached","tier":"promoted"}') | Add-Content "$bus\$task\bus.$sid.jsonl"
   Remove-Item -LiteralPath "$bus\_sessions\$sid" -Force -EA SilentlyContinue
   Remove-Item -LiteralPath "$bus\$task\watermark.$sid.json" -Force -EA SilentlyContinue
   ```
3. If `$ARGUMENTS` contains `--purge` AND no other `_sessions` pointer references this task, delete the
   whole task dir with a LITERAL path: `Remove-Item -LiteralPath "$bus\$task" -Recurse -Force`.
   (Never purge while the other hand is still attached — check for other pointers first.)
4. Confirm: "Detached from `<task>`." (+ "purged the bus" if applicable.)
