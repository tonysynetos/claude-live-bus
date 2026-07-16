# SessionStart hook: surface THIS session's own session_id to the agent.
# Keystone for the live-bus pairing design: /pair and /bus must name their bus files
# with the REAL session_id, because live-bus-read.ps1 keys off the session_id it gets
# on stdin. The agent otherwise has no reliable way to know its own id, so it guessed
# — and any mismatch made pairing fail SILENTLY. This makes the id deterministic.
# Cheap: one short line per session start.

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$raw = [Console]::In.ReadToEnd()
$sid = ""
try { $sid = ($raw | ConvertFrom-Json).session_id } catch {}
if (-not $sid) { exit 0 }

$msg = "LIVE-BUS: this session's session_id is $sid -- use this EXACT value for /pair and /bus (the read-hook keys off the real session_id; any other value fails silently)."
$out = @{ hookSpecificOutput = @{ hookEventName = "SessionStart"; additionalContext = $msg } }
$out | ConvertTo-Json -Depth 5 -Compress
exit 0
