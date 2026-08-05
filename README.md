# claude-live-bus

Shared working memory for two concurrent Claude Code sessions: same brain, two hands.

Live-bus keeps coordination outside either repository. Paired sessions can claim lanes, release them when finished, and share evidence-backed findings without the user relaying messages. It is deliberately a small local mechanism: PowerShell, JSONL files, and a tiny Node gate; no server, database, MCP, or external dependency.

## How it works

- session-id-inject.ps1 is a SessionStart hook. It gives each session its real session_id, so pairing cannot silently write to an orphaned bus file.
- /pair <task-id> attaches a session to a shared task and establishes the standing claim / done / finding protocol.
- live-bus-post.ps1 is the validated writer used by /bus and by the autonomous protocol. It rejects unpaired sessions, invalid kinds, empty or overlong text, and unsupported promotions.
- live-bus-read.ps1 reads peer updates at UserPromptSubmit. It records a pending watermark only.
- live-bus-commit.ps1 runs at Stop and promotes the pending watermark after the turn completes. A cancelled turn therefore replays its updates instead of losing them.
- live-bus-peek.mjs is the PreToolUse gate. It runs cheaply on every tool call and launches the PowerShell reader only when a peer has a newer file, enabling mid-turn delivery.
- /unpair detaches a session; use /unpair --purge only when all collaborators are done.

Each session appends only to its own bus.<session-id>.jsonl file. This avoids concurrent writes to a shared JSONL file, so no locking is needed.

## v2 guarantees

| Mechanism | Result |
| --- | --- |
| Pending then committed watermark | At-least-once delivery: a cancelled turn can replay an update, but does not silently lose it. |
| Claim replay plus heartbeat | Open lanes remain visible until a matching done or leave; silent owners are marked STALE after 15 minutes, never auto-released. |
| Priority eviction | At most 20 updates are injected at once; claim and done entries are retained ahead of chatter. |
| Evidence-gated promotion | A promoted finding must carry an evidence receipt (commit, file:line, or command), otherwise the reader treats it as provisional. |
| Node PreToolUse gate | Solo and idle sessions avoid the expensive PowerShell reader on every tool call. |

This is coordination memory, not a code-sharing mechanism. When two sessions change the same repository, give them separate git worktrees.

## Requirements

- Windows
- Claude Code
- PowerShell 5.1+ (PowerShell 7 also works)
- Node.js for the optional-but-recommended mid-turn PreToolUse gate

## Install

1. Copy the files in hooks\ to %USERPROFILE%\.claude\hooks\ and commands\ to %USERPROFILE%\.claude\commands\.
2. Merge the following entries into the corresponding arrays in %USERPROFILE%\.claude\settings.json. Do not replace unrelated hook entries.
3. Adjust the node.exe path if Node is installed elsewhere.
4. Restart Claude Code sessions so SessionStart can inject each session id.

~~~json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -File \"C:/Users/<you>/.claude/hooks/session-id-inject.ps1\""
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -File \"C:/Users/<you>/.claude/hooks/live-bus-read.ps1\""
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "\"C:/Program Files/nodejs/node.exe\" \"C:/Users/<you>/.claude/hooks/live-bus-peek.mjs\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -File \"C:/Users/<you>/.claude/hooks/live-bus-commit.ps1\""
          }
        ]
      }
    ]
  }
}
~~~

If the Node gate is unavailable, the UserPromptSubmit and Stop hooks still provide turn-boundary coordination; the gate supplies the v2 mid-turn path.

## Use

In each session:

~~~text
/pair <shared-task-id>
~~~

Before a distinct unit of work, claim it. Post done the moment it is completed or abandoned. Post a finding only when it changes what the other session should do. Use evidence only for a fact you actually checked.

~~~powershell
powershell -NoProfile -File "$env:USERPROFILE\.claude\hooks\live-bus-post.ps1" -Sid "<real-session-id>" -Kind claim -Lane "api-route" -Text "updating the API route"
powershell -NoProfile -File "$env:USERPROFILE\.claude\hooks\live-bus-post.ps1" -Sid "<real-session-id>" -Kind done -Lane "api-route" -Text "API route complete" -Evidence "src/routes.ts:42"
~~~

Do not post progress narration or acknowledgements of another session's message. The bus is a coordination channel, not a chat.

## Test

After installing the hooks, run the self-test from this checkout:

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\live-bus-test.ps1
~~~

It creates and removes only a _selftest task under %USERPROFILE%\.claude\live-bus\. The test covers pending/committed delivery, tool-mode delivery, priority eviction, evidence enforcement, open-lane handling, the Node gate, the writer, and the reader footer.

## Parallel subagents

The same file format can support a write-only progress bus for parallel subagents. Only the coordinator reads it; agents still return their normal structured result. See docs/agent-bus-protocol.md.

## File format

Each line in %USERPROFILE%\.claude\live-bus\<task>\bus.<session-id>.jsonl is one JSON object:

~~~json
{
  "session": "<sid>",
  "ts": 1784196342392,
  "kind": "claim|finding|done|note|join|leave",
  "text": "short one-line update",
  "tier": "scratch|promoted",
  "lane": "optional-lane-name",
  "evidence": "optional verification receipt"
}
~~~

Never put credentials, guest data, financial data, or other sensitive information on the bus: it is plaintext local working memory.

## License

MIT
