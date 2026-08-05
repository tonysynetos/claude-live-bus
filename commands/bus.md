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
3. Post it with the validating helper (preferred — it refuses malformed lines rather than writing
   something the other hand mis-reads). This is the same helper a session uses when it coordinates
   autonomously under the standing protocol in `/pair`:

   ```powershell
   powershell -NoProfile -File "$env:USERPROFILE\.claude\hooks\live-bus-post.ps1" `
     -Sid "<real-session-id>" -Kind <claim|done|finding|note|leave> -Text "<one line>" `
     [-Lane "<lane>"] [-Evidence "<sha | file:line | command>"]
   ```

   Raw equivalent, if you need a field the helper does not expose (one-writer-per-file — never
   write another session's):

   ```powershell
   $sid = "<real-session-id-from-the-LIVE-BUS-line>"; $bus = "$env:USERPROFILE\.claude\live-bus"
   $task = (Get-Content "$bus\_sessions\$sid" -Raw).Trim()
   $ts = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
   $obj = @{ session=$sid; ts=$ts; kind="<kind>"; text="<text>"; tier="scratch" }
   if ("<lane>")     { $obj.lane = "<lane>" }
   if ("<evidence>") { $obj.evidence = "<evidence>"; $obj.tier = "promoted" }
   ($obj | ConvertTo-Json -Compress) | Add-Content "$bus\$task\bus.$sid.jsonl"
   ```
4. Confirm in one line: "posted to bus `<task>`: <kind> <text>".

## Rules
- `finding` is ALWAYS `tier:scratch` (provisional) unless you just verified it against git/files/data.
  To promote, set `evidence` to the receipt — a commit sha, `file.ts:42`, or the command you ran.
  **The read-hook demotes any `promoted` line carrying no `evidence`**, so promoting without a
  receipt isn't a shortcut — it just arrives looking sloppy. Never promote on a hunch; the other
  hand builds on promoted as fact.
- `claim` before you start a lane, and always pass `lane:<name>`. Open claims are replayed to the
  other hand as OPEN LANES until you post a matching `done` (or a bare `leave`, which clears all of
  yours). A claim whose owner goes quiet for 15 minutes is shown STALE, but **nothing auto-releases
  it — post `done` when you finish a lane.**
- Keep text ONE line and under 600 chars; longer is truncated for the other hand. Split a long
  update into several short lines rather than one paragraph.
- No secrets, no guest/financial data (same rule as any log).
