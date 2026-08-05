param([ValidateSet('prompt','tool')][string]$Mode = 'prompt')

# Live-bus reader for paired 2-session work. ONE script, two hook entry points:
#   -Mode prompt  (UserPromptSubmit) — turn-boundary delivery, the v1 behaviour
#   -Mode tool    (PreToolUse, matcher *) — v2 Tier 1: near-real-time delivery, so a
#                 session grinding autonomously through tool calls still hears the
#                 other hand instead of going deaf until its user types again.
# If this session is not /pair-attached, both modes exit instantly — that must stay
# true, because -Mode tool runs on EVERY tool call.
# Design: toolbox/memory-architecture.md. v1 2026-07-15. v2 Tier 0+1 2026-08-03.
#
# WATERMARK MODEL (three files per session, all in the task dir):
#   watermark.<sid>.json          COMMITTED — lines this session has seen AND finished a turn on
#   watermark.pending.<sid>.json  PENDING   — shown but not yet survived a completed turn
#   peekmark.<sid>.json           PEEK      — cheap mtime gate so -Mode tool can bail without parsing
# prompt mode reads from COMMITTED (ignoring pending) — that is the at-least-once
# guarantee: a cancelled turn never commits, so its lines surface again.
# tool mode reads from max(COMMITTED, PENDING) — otherwise it would re-show the same
# lines on every tool call within one turn.
# live-bus-commit.ps1 (Stop hook) promotes PENDING -> COMMITTED when a turn completes.

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::InputEncoding  = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$raw = [Console]::In.ReadToEnd()
$sid = ""
try { $sid = ($raw | ConvertFrom-Json).session_id } catch {}
if (-not $sid) { exit 0 }

$busRoot = Join-Path $env:USERPROFILE ".claude\live-bus"
$ptr = Join-Path $busRoot "_sessions\$sid"
if (-not (Test-Path $ptr)) { exit 0 }          # not paired -> silent, instant

$task = (Get-Content $ptr -Raw -EA SilentlyContinue).Trim()
if (-not $task) { exit 0 }
$taskDir = Join-Path $busRoot $task
if (-not (Test-Path $taskDir)) { exit 0 }

$peerFiles = @(Get-ChildItem $taskDir -Filter "bus.*.jsonl" -File -EA SilentlyContinue |
               Where-Object { $_.Name -ne "bus.$sid.jsonl" })
if ($peerFiles.Count -eq 0) { exit 0 }

# ---- fast path (tool mode only) -----------------------------------------
# One directory listing, no JSON parsing. Appends bump a file's LastWriteTime, so
# comparing the newest peer-file mtime against our peekmark is enough to know
# whether anything can possibly be new. This runs on every tool call — keep it cheap.
$newestTicks = ($peerFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc.Ticks
$peekFile = Join-Path $taskDir "peekmark.$sid.json"
if ($Mode -eq 'tool') {
    $peek = 0
    if (Test-Path $peekFile) { try { $peek = [long]((Get-Content $peekFile -Raw | ConvertFrom-Json).ticks) } catch { $peek = 0 } }
    if ($newestTicks -le $peek) { exit 0 }
}

$wmFile   = Join-Path $taskDir "watermark.$sid.json"
$pendFile = Join-Path $taskDir "watermark.pending.$sid.json"
$committed = 0
if (Test-Path $wmFile)   { try { $committed = [long]((Get-Content $wmFile   -Raw | ConvertFrom-Json).ts) } catch { $committed = 0 } }
$pending = 0
if (Test-Path $pendFile) { try { $pending   = [long]((Get-Content $pendFile -Raw | ConvertFrom-Json).ts) } catch { $pending = 0 } }

$threshold = if ($Mode -eq 'tool') { [Math]::Max($committed, $pending) } else { $committed }

# ---- parse every peer line once (needed for both new-lines and open-claims) ----
$all = @()
foreach ($f in $peerFiles) {
    foreach ($ln in (Get-Content $f.FullName -Encoding UTF8 -EA SilentlyContinue)) {
        if (-not $ln.Trim()) { continue }
        try { $o = $ln | ConvertFrom-Json } catch { continue }
        if ($null -eq $o.ts) { continue }
        $all += $o
    }
}
if ($all.Count -eq 0) { exit 0 }
$all = @($all | Sort-Object { [long]$_.ts })
$new = @($all | Where-Object { [long]$_.ts -gt $threshold })

# Always advance the peek gate, even with nothing new, so tool mode stops re-parsing.
"{`"ticks`": $newestTicks}" | Set-Content $peekFile -Encoding UTF8
if ($new.Count -eq 0) { exit 0 }
$maxTs = [long]($new[-1].ts)

$nowMs = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())

# ---- heartbeat (throttled) ----------------------------------------------
# Proves this session is alive so the other hand can tell a live claim from an
# abandoned one. Written at most once a minute — this runs on every tool call.
$hbFile = Join-Path $taskDir "heartbeat.$sid.json"
$lastHb = 0
if (Test-Path $hbFile) { try { $lastHb = [long]((Get-Content $hbFile -Raw | ConvertFrom-Json).ts) } catch { $lastHb = 0 } }
if (($nowMs - $lastHb) -gt 60000) { "{`"ts`": $nowMs}" | Set-Content $hbFile -Encoding UTF8 }

# ---- open claims ---------------------------------------------------------
# v1 had no notion of a claim ending, so a crashed session's lane stayed locked
# forever with nothing to reveal it. Replay each peer's claim/done/leave history,
# then flag any surviving claim whose owner has gone quiet.
$STALE_MS = 15 * 60 * 1000
$open = @{}
foreach ($o in $all) {
    $k = "$($o.kind)"
    if ($k -ne 'claim' -and $k -ne 'done' -and $k -ne 'leave') { continue }
    $lane = if ($o.lane) { "$($o.lane)" } else { "" }
    $key  = "$($o.session)|$lane"
    if ($k -eq 'claim') { $open[$key] = $o; continue }
    if ($k -eq 'leave' -and -not $lane) {
        foreach ($kk in @($open.Keys)) { if ($kk -like "$($o.session)|*") { $open.Remove($kk) } }
        continue
    }
    $open.Remove($key)
}
$claimLines = @()
foreach ($c in ($open.Values | Sort-Object { [long]$_.ts })) {
    $cs   = "$($c.session)"
    $who  = $cs.Substring(0, [Math]::Min(8, $cs.Length))
    $ageM = [int](($nowMs - [long]$c.ts) / 60000)
    $lane = if ($c.lane) { " [$($c.lane)]" } else { "" }
    $hb = Join-Path $taskDir "heartbeat.$cs.json"
    $stale = ""
    if (Test-Path $hb) {
        $t = 0; try { $t = [long]((Get-Content $hb -Raw | ConvertFrom-Json).ts) } catch { $t = 0 }
        if (($nowMs - $t) -gt $STALE_MS) { $stale = " (STALE - owner silent $([int](($nowMs - $t)/60000))m; clear by hand if abandoned)" }
    } else {
        $stale = " (STALE - owner never checked in)"
    }
    $claimLines += "  - {0}{1} {2}m ago{3} :: {4}" -f $who, $lane, $ageM, $stale, "$($c.text)"
}

# ---- size cap with priority eviction -------------------------------------
# WHICH lines get cut matters more than how many: evicting a `claim` is how two
# hands collide. claim/done outrank findings, which outrank chatter.
$MAXLINES = 20
$PRIO = @{ 'claim' = 0; 'done' = 0; 'finding' = 1; 'note' = 2; 'join' = 3; 'leave' = 3 }
$dropInfo = ""
if ($new.Count -gt $MAXLINES) {
    $ranked = $new | Sort-Object `
        @{ Expression = { $p = $PRIO[[string]$_.kind]; if ($null -eq $p) { 2 } else { $p } } }, `
        @{ Expression = { [long]$_.ts }; Descending = $true }
    $kept    = @($ranked | Select-Object -First $MAXLINES)
    $dropped = @($ranked | Select-Object -Skip $MAXLINES)
    $byKind = ($dropped | Group-Object { [string]$_.kind } | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ", "
    $dropInfo = " [$($dropped.Count) older line(s) held back: $byKind - claims/dones are never dropped]"
    $new = @($kept | Sort-Object { [long]$_.ts })
}

$lines = @()
foreach ($o in $new) {
    $sessStr = "$($o.session)"
    $who  = $sessStr.Substring(0, [Math]::Min(8, $sessStr.Length))
    $lane = if ($o.lane) { " [$($o.lane)]" } else { "" }
    # Evidence-gated promotion: `promoted` is a claim of verification, so it has to
    # carry the receipt. Without one the hook silently demotes it rather than letting
    # an unchecked hunch reach the other hand dressed as fact.
    $ev = "$($o.evidence)"
    $tier = ""
    if ($o.tier -eq "promoted") {
        if ($ev) { $tier = " [verified: $ev]" }
        else     { $tier = " (provisional - marked promoted but carried no evidence)" }
    } else {
        $tier = " (provisional)"
    }
    $txt = "$($o.text)"
    if ($txt.Length -gt 600) { $txt = $txt.Substring(0,600) + "…[truncated - full text in the task dir]" }
    $lines += "  - {0} {1}{2}{3} :: {4}" -f $who, "$($o.kind)", $lane, $tier, $txt
}

$when = if ($Mode -eq 'tool') { "just now, mid-turn" } else { "since your last turn" }
$msg  = "LIVE-BUS (task '$task') -- $when the other hand recorded:$dropInfo`n" + ($lines -join "`n")
if ($claimLines.Count -gt 0) {
    $msg += "`nOPEN LANES held by other hands (do not start these):`n" + (($claimLines | Select-Object -First 10) -join "`n")
}
# Write-side reinforcement. Without this the bus is read-only in practice: sessions
# hear each other and never speak, and the user ends up relaying by hand. The bootstrap
# copy lives in commands/pair.md (this footer can't bootstrap — it only fires once the
# OTHER hand has already posted, so if neither speaks first neither is ever told to).
$msg += "`nProvisional = unverified; verify before building on it. Do NOT start a lane listed above."
$msg += "`nYOUR side of the protocol, unprompted: claim a lane before you start it, post done the moment"
$msg += " you finish it, and post a finding only when it would change what the other hand does --"
$msg += " powershell -NoProfile -File `"`$env:USERPROFILE\.claude\hooks\live-bus-post.ps1`" -Sid <your-session-id> -Kind claim|done|finding -Lane <lane> -Text <one line>"
$msg += "`nNever post in reaction to this message; only ever post about your own work. Full log: $taskDir"

# Pending only. The Stop hook commits it once the turn actually finishes.
"{`"ts`": $maxTs}" | Set-Content $pendFile -Encoding UTF8

$evt = if ($Mode -eq 'tool') { "PreToolUse" } else { "UserPromptSubmit" }
$out = @{ hookSpecificOutput = @{ hookEventName = $evt; additionalContext = $msg } }
$out | ConvertTo-Json -Depth 5 -Compress
exit 0
