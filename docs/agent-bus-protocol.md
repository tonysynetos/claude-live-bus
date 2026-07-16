# Agent-Bus Protocol (live-bus for parallel subagents)

Extends the 2-session live-bus (`/pair`, `/bus`, `live-bus-read.ps1`) to parallel subagents.
**Write-only for agents; only the coordinator reads.**

## Why not a full symmetric bus for agents
- Subagents get no UserPromptSubmit hook injections — they'd have to poll by instruction, and
  cheap-tier agents forget soft instructions; mid-flight reads add Bash-permission friction per agent.
- For wave-based fan-outs, structured return values already give the coordinator everything at wave end.
- What the write-only bus adds on top of return values: live progress visibility mid-wave, a durable
  post-hoc lane audit (who claimed/found what, when), and partial results surviving a dead agent.

## Protocol
1. **Task id:** coordinator picks `agentbus-<slug>-<shortrand>` and creates
   `~/.claude/live-bus/<task>/` before dispatch. No `_sessions` pointer is written for agents
   (they never read, so the read-hook stays out of their way).
2. **Agent identity:** `agent-<task>-<n>` (never bare `agent-1` — collides across runs).
3. **Dispatch template** — paste into every subagent prompt, filling TASK and AGENT:

   ```
   Progress bus: after each meaningful finding or when you claim/finish a lane, append ONE line
   via PowerShell (kind = claim|finding|done|note; keep text one line, no secrets):

   $ts=[long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()); ('{"session":"<AGENT>","ts":'+$ts+',"kind":"<KIND>","text":"<TEXT>","tier":"scratch"}') | Add-Content "$env:USERPROFILE\.claude\live-bus\<TASK>\bus.<AGENT>.jsonl"

   Mark tier "promoted" ONLY for facts you verified against files/git/data. This bus is
   supplementary — still return your full structured result normally.
   ```
4. **Coordinator reads** whole `bus.*.jsonl` files between waves (no watermark needed) and may
   post its own lines as `agent-<task>-coord`.
5. **Cleanup:** delete `~/.claude/live-bus/<task>` when the fan-out is done (or keep the dir as
   the audit artifact).

## Semantics (same as the session bus)
- One writer per file; append-only JSONL; ms epoch timestamps (UTC).
- `scratch` = provisional, verify before building on it; `promoted` = verified.
- Delivery to a *paired human session* is at-most-once notification; the files are the durable truth.
- Claims have no TTL — the coordinator clears stale claims from dead agents.

## When to use
- Long-running parallel agents where lanes could collide or progress visibility matters.
- Skip it for short fan-outs (< ~2 min/agent) — return values alone are cheaper.
