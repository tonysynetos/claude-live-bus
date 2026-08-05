---
description: Attach THIS session to a live-bus task so two concurrent sessions coordinate themselves — claiming lanes, releasing them, and sharing verified findings autonomously, without the user relaying. Usage — /pair <task-id>. Both sessions run it with the SAME task-id. Design — toolbox/memory-architecture.md.
argument-hint: "<task-id>   (a short shared slug both sessions agree on, e.g. `owner-reconcile` or `auth-sweep`)"
---

# /pair — attach to a live-bus task

Goal: two Claude Code sessions cooperate on ONE task, **coordinating themselves** — each claims the
lane it is about to work, releases it when done, and shares findings the other would act on. The
user does not relay messages. Code stays isolated (use worktrees); only MEMORY is shared, via files
outside either tree. Delivery is near-real-time (per tool call), not true real-time — an idle or
blocked session still receives nothing until it acts.

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
3. **Adopt the standing protocol below for the rest of this session.** It is the point of pairing —
   without it the bus is read-only in practice and the user ends up relaying by hand.
4. Tell the user: "Paired to `<task-id>`. Run `/pair <task-id>` in the OTHER session with the same id.
   I'll claim and release lanes myself — you don't need to relay." Then recommend worktrees if both
   sessions are in the same repo (`using-git-worktrees`) — the bus shares memory, NOT code, so two
   hands in one working tree still clobber each other.

---

## Standing protocol (follow autonomously once attached — do not wait to be asked)

Post with the helper; it validates and refuses bad lines rather than writing something the other
hand will mis-read. `<sid>` is this session's real session_id.

```powershell
powershell -NoProfile -File "$env:USERPROFILE\.claude\hooks\live-bus-post.ps1" -Sid "<sid>" -Kind claim -Lane "<lane>" -Text "<one line>"
```

**CLAIM — before you start a distinct lane of work.** A lane is something another hand could
plausibly touch at the same time: a file, a subsystem, a migration, a doc, a deploy. Claim it
*before* the first edit, not after. Name the lane in kebab-case (`-Lane "eslint-config"`). Do not
claim per tool call — claim per unit of work.

**DONE — the moment a lane is finished or abandoned.** Same `-Lane` value. Nothing auto-releases a
claim; an unreleased lane blocks the other hand until a human clears it. If you drop a lane without
finishing, still post `done` and say so.

**FINDING — only when it would change what the other hand does.** A shared root cause, a broken
assumption, a schema/API/interface change, a landed commit that alters the tree they are working in.
Add `-Evidence "<commit sha | file.ts:42 | command you ran>"` ONLY when you actually verified it —
that promotes the line, and the reader mechanically demotes a promotion with no evidence.

**Do NOT post:** progress narration, plans, restatements of what the other hand just said, or
anything you have not done yet. Silence is the correct default; the bus is a coordination channel,
not a chat.

**Anti-loop rule — the one that keeps this from degenerating.** Never post *in reaction to* a post.
Only ever post about your OWN work. If the other hand's line changes your plan, change your plan
silently. Two agents that acknowledge each other will ping-pong until the line cap evicts real
coordination.

**On receiving an OPEN LANES block:** do not start a lane another hand holds. Pick a different one,
or if you must have it, post a `note` asking them to release — then continue with something else
rather than blocking.

**Before you finish your turn:** if you claimed anything that is now complete, post `done`. A
session that ends holding lanes strands them.

---

## Notes
- Silent for solo sessions: the read-hook exits instantly unless a session is paired. The
  `PreToolUse` gate is Node for this reason (~62 ms/call idle; a PowerShell gate measured 339 ms).
- **Delivery is at-least-once.** A cancelled turn never commits its watermark, so those lines
  surface again — expect the occasional duplicate; never assume a line was consumed.
- **Claims do not expire.** After 15 minutes of owner silence a lane is shown STALE, but nothing
  releases it. STALE is a signal to a human, not a lock timeout.
- Line cap is 20 per injection with priority eviction — `claim`/`done` are never dropped, chatter
  goes first. Keep every line under 600 chars or it is truncated.
- `/bus` is the manual escape hatch (same helper); `/unpair` detaches. The bus is ephemeral per
  task — delete `~/.claude/live-bus/<task>` when both hands are done.
- Self-test after any change to the mechanism: `~/.claude/hooks/_backups/test-live-bus-v2.ps1`.
