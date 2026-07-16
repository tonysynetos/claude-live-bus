# UserPromptSubmit hook: live-bus reader for paired 2-session work.
# If THIS session is attached to a live-bus task (/pair), surface what the OTHER
# hand(s) recorded since this session's last turn. If not attached, exit instantly —
# this must be near-zero cost for the 99% solo case.
# Design rationale: see README.md.

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

# Watermark: last epoch-ms this session has already seen.
$wmFile = Join-Path $taskDir "watermark.$sid.json"
$wm = 0
if (Test-Path $wmFile) { try { $wm = [long]((Get-Content $wmFile -Raw | ConvertFrom-Json).ts) } catch { $wm = 0 } }

# Gather lines from every OTHER session's bus file newer than the watermark.
$new = @()
Get-ChildItem $taskDir -Filter "bus.*.jsonl" -File -EA SilentlyContinue | ForEach-Object {
    if ($_.Name -eq "bus.$sid.jsonl") { return }   # skip my own writes
    foreach ($ln in (Get-Content $_.FullName -Encoding UTF8 -EA SilentlyContinue)) {
        if (-not $ln.Trim()) { continue }
        try { $o = $ln | ConvertFrom-Json } catch { continue }
        if ([long]$o.ts -gt $wm) { $new += $o }
    }
}

if (-not $new -or $new.Count -eq 0) { exit 0 }
$new = $new | Sort-Object { [long]$_.ts }
$maxTs = [long]($new[-1].ts)

# Note: claims have no TTL — a claim stands until a `done`/`leave` or the task dir is purged.
# Size cap: a chatty peer must not blow up this turn's context. Per-line 300 chars, 20 lines max.
$dropped = 0
if ($new.Count -gt 20) { $dropped = $new.Count - 20; $new = $new[-20..-1] }
$lines = @()
foreach ($o in $new) {
    $sessStr = "$($o.session)"
    $who = $sessStr.Substring(0, [Math]::Min(8, $sessStr.Length))
    $lane = if ($o.lane) { " [$($o.lane)]" } else { "" }
    $tier = if ($o.tier -eq "promoted") { "" } else { " (provisional)" }
    $kind = "$($o.kind)"
    $txt  = "$($o.text)"
    if ($txt.Length -gt 300) { $txt = $txt.Substring(0,300) + "…[truncated]" }
    $lines += "  - {0} {1}{2}{3} :: {4}" -f $who, $kind, $lane, $tier, $txt
}

$header = "LIVE-BUS (task '$task') -- since your last turn, the other hand recorded:"
if ($dropped -gt 0) { $header += " (showing newest 20 of $($new.Count + $dropped); read the bus.*.jsonl files for the rest)" }
$footer = "Provisional = unverified; verify before building on it. If you are about to start a lane another hand already claimed, pick a different lane or coordinate."
$msg = $header + "`n" + ($lines -join "`n") + "`n" + $footer

# advance watermark
$null = New-Item -ItemType Directory -Force -Path $taskDir -EA SilentlyContinue
"{`"ts`": $maxTs}" | Set-Content $wmFile -Encoding UTF8

$out = @{ hookSpecificOutput = @{ hookEventName = "UserPromptSubmit"; additionalContext = $msg } }
$out | ConvertTo-Json -Depth 5 -Compress
exit 0
