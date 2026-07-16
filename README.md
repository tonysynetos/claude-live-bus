# claude-live-bus

**Shared memory between concurrent Claude Code sessions — "same brain, two hands."**

Two (or more) Claude Code sessions working on the same task can share findings and coordinate
who-does-what, live, at turn boundaries — with **zero cost to normal solo sessions**. Pure
PowerShell + JSONL files. No server, no database, no MCP, no dependencies.

```
Session A                                Session B
   │  /pair owner-reconcile                 │  /pair owner-reconcile
   │  /bus claim lane:invoices ...          │
   │                                        │  (next turn) LIVE-BUS: A claimed [invoices]
   │                                        │  /bus finding "bank export is missing June"
   │  (next turn) LIVE-BUS: B found ...     │
```

## How it works

- **`session-id-inject.ps1`** (SessionStart hook) — tells each session its own real `session_id`.
  Without this, the model has no reliable way to know its own id and pairing fails silently.
- **`/pair <task-id>`** — attaches a session to a task: writes a reverse-pointer
  `~/.claude/live-bus/_sessions/<sid>` → task, creates `~/.claude/live-bus/<task>/`.
- **`/bus <claim|finding|done|note> [lane:<name>] <text>`** — appends one JSON line to that
  session's **own** bus file (`bus.<sid>.jsonl`). One writer per file — no locking needed.
- **`live-bus-read.ps1`** (UserPromptSubmit hook) — on every prompt: if this session is paired,
  it surfaces every line from **other** sessions' bus files newer than a per-session watermark,
  then advances the watermark. If not paired, it exits instantly (one `Test-Path`).
- **`/unpair [--purge]`** — detaches; `--purge` deletes the task dir when everyone's done.

### Design decisions (the why)

| Decision | Why |
|---|---|
| Turn-boundary delivery, not real-time | UserPromptSubmit is the only injection point the harness gives you. Accept the ceiling. |
| One writer per file (`bus.<sid>.jsonl`) | Concurrent appends to a shared file on Windows are a corruption lottery. Per-writer files need no locks. |
| Per-session watermark files | Each reader tracks what it has seen; readers never mutate writers' files. |
| `scratch` vs `promoted` tiers | An unverified finding surfaced as fact poisons the other session. Provisional-by-default keeps the shared-truth guarantee honest. |
| At-most-once delivery | The watermark advances at read time; a canceled prompt can drop an injection. The JSONL files remain the durable truth — no ack machinery. |
| Size caps (20 lines / 300 chars) | A chatty peer must not blow up the other session's context window. Overflow points at the files. |
| Ephemeral per-task dirs | The bus is working memory, not an archive. Purge on `/unpair --purge`. |
| Memory shared, code isolated | Pair the *knowledge*; keep working trees separate (git worktrees) so the hands never fight over files. |

### Known limitations (accepted, documented)

- **Not real-time:** the other hand sees your line at its *next turn*, not immediately.
- **At-most-once:** see above. Rare; files re-readable manually.
- **No claim TTL:** a crashed session's `claim` stands until cleared by hand or purge.
- **Millisecond-tie edge:** a line with `ts` exactly equal to the watermark written *after* the
  previous read is skipped. Negligible in practice.
- **PowerShell spawn floor:** every hook invocation pays ~100–200 ms process spawn (Windows).
  The unpaired path adds nothing measurable beyond that.

## Parallel subagents

The same bus extends to fan-outs of parallel subagents — but **write-only**: agents append
claims/findings via a one-line template in their dispatch prompt; only the coordinator reads,
between waves. Rationale and dispatch template: [docs/agent-bus-protocol.md](docs/agent-bus-protocol.md).

## Install

Requirements: Windows, Claude Code, PowerShell 5.1+ (works on 7+ too).

1. Copy `hooks/*.ps1` to `%USERPROFILE%\.claude\hooks\`.
2. Copy `commands/*.md` to `%USERPROFILE%\.claude\commands\` (adds `/pair`, `/bus`, `/unpair`).
3. Register both hooks in `%USERPROFILE%\.claude\settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
          "command": "powershell -NoProfile -File \"C:/Users/<you>/.claude/hooks/session-id-inject.ps1\"" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
          "command": "powershell -NoProfile -File \"C:/Users/<you>/.claude/hooks/live-bus-read.ps1\"" } ] }
    ]
  }
}
```

4. Restart your sessions (the SessionStart hook must run once so each session knows its id).

macOS/Linux: the design ports directly (bash + jq instead of PowerShell); PRs welcome.

## Test

A self-contained 16-test harness runs the real hook as a subprocess against sandboxed synthetic
sessions — it never touches your repos or real sessions:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\live-bus-test.ps1
```

Covers: unpaired fast path + latency, other-hand visibility, own-line skipping, watermark
advance, ts ordering, malformed/torn JSONL lines, unicode through stdout, provisional/promoted
labeling, lanes, 3-session fan-in, corrupt-watermark degradation (replays instead of losing),
empty peer files, per-line truncation, flood capping.

## File format

`~/.claude/live-bus/<task>/bus.<session-id>.jsonl`, one JSON object per line:

```json
{"session":"<sid>","ts":1784196342392,"kind":"claim|finding|done|note|join|leave","text":"...","tier":"scratch|promoted","lane":"optional-lane-name"}
```

`ts` is UTC epoch milliseconds. Never put secrets or sensitive data on the bus — it's a plaintext log.

## License

MIT
