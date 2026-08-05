# Stop hook: commit the live-bus read watermark for paired 2-session work.
# Half of the at-least-once delivery guarantee introduced in live-bus v2 (2026-08-03).
#
# live-bus-read.ps1 (UserPromptSubmit) shows the other hand's lines and records only a
# PENDING watermark. This hook fires when the turn actually completes and promotes that
# pending value to the committed watermark the reader trusts.
#
# The point: if a turn is cancelled or dies, Stop does not run, nothing is committed, and
# the reader re-surfaces those lines next turn. v1 advanced the watermark at read time, so
# a cancelled prompt silently ate lines with no trace. At-least-once beats at-most-once
# here — a duplicate line costs a few tokens, a dropped `claim` costs a collision.
#
# Silent and instant for unpaired sessions (the overwhelmingly common case).

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$raw = [Console]::In.ReadToEnd()
$sid = ""
try { $sid = ($raw | ConvertFrom-Json).session_id } catch {}
if (-not $sid) { exit 0 }

$busRoot = Join-Path $env:USERPROFILE ".claude\live-bus"
$ptr = Join-Path $busRoot "_sessions\$sid"
if (-not (Test-Path $ptr)) { exit 0 }          # not paired → silent, instant

$task = (Get-Content $ptr -Raw -EA SilentlyContinue).Trim()
if (-not $task) { exit 0 }
$taskDir = Join-Path $busRoot $task
if (-not (Test-Path $taskDir)) { exit 0 }

$pendingFile = Join-Path $taskDir "watermark.pending.$sid.json"
if (-not (Test-Path $pendingFile)) { exit 0 }  # nothing was read this turn

$pending = 0
try { $pending = [long]((Get-Content $pendingFile -Raw | ConvertFrom-Json).ts) } catch { $pending = 0 }
if ($pending -le 0) { Remove-Item $pendingFile -Force -EA SilentlyContinue; exit 0 }

# Never move the watermark backwards (a stale pending file must not un-read newer lines).
$wmFile = Join-Path $taskDir "watermark.$sid.json"
$committed = 0
if (Test-Path $wmFile) { try { $committed = [long]((Get-Content $wmFile -Raw | ConvertFrom-Json).ts) } catch { $committed = 0 } }

if ($pending -gt $committed) {
    "{`"ts`": $pending}" | Set-Content $wmFile -Encoding UTF8
}
Remove-Item $pendingFile -Force -EA SilentlyContinue
exit 0
