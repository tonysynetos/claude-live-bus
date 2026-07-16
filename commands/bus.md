---
description: Write a line to the live-bus so the OTHER paired session sees it at its next turn. Usage — /bus <claim|finding|done|note> <text>. Requires this session be /pair-attached first. claim = leasing a lane (the other hand avoids it); finding = something you learned (provisional until verified); done = finished a lane; note = anything else.
argument-hint: "<claim|finding|done|note> [lane:<name>] <text>"
---

# /bus — post to the live-bus

Requires this session to be `/pair`-attached (a `~/.claude/live-bus/_sessions/<session-id>` pointer
exists). If not attached, tell the user to `/pair <task-id>` first.

## Steps
1. Parse `$ARGUMENTS`: first word = `kind` (claim|finding|done|note); optional `lane:<name>`; rest = text.
2. Use this session's REAL `session_id` (injected at session start: `LIVE-BUS: this session's session_id is <sid>`) — never guess it; a wrong id writes to an orphan file the other hand never reads. Its task = the pointer `~/.claude/live-bus/_sessions/<session-id>`.
3. Append the line to THIS session's own bus file (one-writer-per-file — never write another session's):

   ```powershell
   $sid = "<real-session-id-from-the-LIVE-BUS-line>"; $bus = "$env:USERPROFILE\.claude\live-bus"
   $task = (Get-Content "$bus\_sessions\$sid" -Raw).Trim()
   $ts = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
   $obj = @{ session=$sid; ts=$ts; kind="<kind>"; text="<text>"; tier="scratch" }
   if ("<lane>") { $obj.lane = "<lane>" }
   ($obj | ConvertTo-Json -Compress) | Add-Content "$bus\$task\bus.$sid.jsonl"
   ```
4. Confirm in one line: "posted to bus `<task>`: <kind> <text>".

## Rules
- `finding` is ALWAYS `tier:scratch` (provisional) unless you just verified it against git/files/data —
  only then set `tier:promoted`. Never promote on a hunch; the other hand builds on promoted as fact.
- `claim` before you start a lane so the other hand takes a different one. Keep claims short-lived.
- Keep text one line, no secrets, no sensitive data (same rule as any log).
