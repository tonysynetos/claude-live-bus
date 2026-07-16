# live-bus-test.ps1 — deterministic test harness for the live-bus read hook.
# Runs the real hook (~/.claude/hooks/live-bus-read.ps1) as a subprocess with synthetic
# session ids under a sandboxed task id. No real repo or real session is touched.
# Usage: powershell -NoProfile -File live-bus-test.ps1
# Exit 0 = all pass. Writes PASS/FAIL log next to itself as live-bus-test-result.log.

$ErrorActionPreference = 'Stop'
$hook = Join-Path $env:USERPROFILE ".claude\hooks\live-bus-read.ps1"
$bus  = Join-Path $env:USERPROFILE ".claude\live-bus"
$task = "bus-selftest-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$td   = Join-Path $bus $task
$sidA = "testsess-aaaa-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$sidB = "testsess-bbbb-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$sidC = "testsess-cccc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$log  = Join-Path $PSScriptRoot "live-bus-test-result.log"

$results = @()
function Assert($name, $cond, $detail) {
    $script:results += [pscustomobject]@{ name = $name; pass = [bool]$cond; detail = $detail }
    $tag = if ($cond) { "PASS" } else { "FAIL" }
    Write-Host ("[{0}] {1}  {2}" -f $tag, $name, $detail)
}

function Invoke-Hook($sid) {
    # Run the hook exactly as the harness does: -NoProfile, JSON on stdin, capture stdout.
    $json = '{"session_id":"' + $sid + '","prompt":"x"}'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($json); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return $out
}

function Bus-Line($sid, $ts, $kind, $text, $tier, $lane) {
    $o = @{ session = $sid; ts = $ts; kind = $kind; text = $text; tier = $tier }
    if ($lane) { $o.lane = $lane }
    ($o | ConvertTo-Json -Compress) | Add-Content -Path (Join-Path $td "bus.$sid.jsonl") -Encoding UTF8
}

function Ctx($raw) {
    # Extract additionalContext from hook stdout JSON (empty string if no output).
    if (-not $raw -or -not $raw.Trim()) { return "" }
    try { return ($raw | ConvertFrom-Json).hookSpecificOutput.additionalContext } catch { return "<PARSE-ERROR>:$raw" }
}

try {
    # --- setup sandbox ---
    New-Item -ItemType Directory -Force -Path $td, (Join-Path $bus "_sessions") | Out-Null
    $now = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())

    # T1: unpaired session -> empty output (fast path)
    $out = Invoke-Hook "testsess-unpaired-000"
    Assert "T1-unpaired-silent" (-not $out.Trim()) "unpaired hook must emit nothing"

    # T11: unpaired latency (includes powershell spawn floor ~100-200ms)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-Hook "testsess-unpaired-000"
    $sw.Stop()
    Assert "T11-unpaired-latency" ($sw.ElapsedMilliseconds -lt 1500) ("elapsed {0}ms (spawn floor included)" -f $sw.ElapsedMilliseconds)

    # pair A and B
    Set-Content (Join-Path $bus "_sessions\$sidA") $task -NoNewline
    Set-Content (Join-Path $bus "_sessions\$sidB") $task -NoNewline

    # T2/T3: B writes; A sees B's line but never its own
    Bus-Line $sidA ($now+1) "note" "A-own-line-should-not-appear" "scratch" $null
    Bus-Line $sidB ($now+2) "finding" "B-found-the-thing" "scratch" $null
    $ctx = Ctx (Invoke-Hook $sidA)
    Assert "T2-sees-other-hand" ($ctx -match "B-found-the-thing") "A must see B's finding"
    Assert "T3-skips-own-lines" ($ctx -notmatch "A-own-line") "A must not see its own line"
    Assert "T8-provisional-label" ($ctx -match "provisional") "scratch tier must be labeled provisional"

    # T4: watermark advanced -> immediate re-run is silent
    $out2 = Invoke-Hook $sidA
    Assert "T4-watermark-advances" (-not $out2.Trim()) "second read with no new lines must be silent"

    # T5: ordering by ts (write out of order, expect sorted)
    Bus-Line $sidB ($now+50) "note" "SECOND-msg" "promoted" $null
    Bus-Line $sidB ($now+10) "note" "FIRST-msg" "promoted" $null
    $ctx = Ctx (Invoke-Hook $sidA)
    $iFirst = $ctx.IndexOf("FIRST-msg"); $iSecond = $ctx.IndexOf("SECOND-msg")
    Assert "T5-ordering" ($iFirst -ge 0 -and $iSecond -gt $iFirst) "FIRST at $iFirst, SECOND at $iSecond"
    Assert "T8b-promoted-unlabeled" ($ctx -notmatch "SECOND-msg \(provisional\)") "promoted tier must not say provisional"

    # T6: malformed + torn (no trailing newline, half a JSON object) lines are skipped, valid one survives
    Add-Content (Join-Path $td "bus.$sidB.jsonl") 'this is not json' -Encoding UTF8
    Add-Content (Join-Path $td "bus.$sidB.jsonl") ('{"session":"'+$sidB+'","ts":'+($now+60)+',"kind":"note","text":"valid-after-garbage","tier":"promoted"}') -Encoding UTF8
    [System.IO.File]::AppendAllText((Join-Path $td "bus.$sidB.jsonl"), '{"session":"torn', [System.Text.UTF8Encoding]::new($false))
    $ctx = Ctx (Invoke-Hook $sidA)
    Assert "T6-malformed-skipped" ($ctx -match "valid-after-garbage" -and $ctx -notmatch "PARSE-ERROR") "garbage + torn line skipped, valid shown"
    # restore clean file end for later tests
    Add-Content (Join-Path $td "bus.$sidB.jsonl") '' -Encoding UTF8

    # T7: unicode survives hook stdout (Greek, em-dash, emoji)
    Bus-Line $sidB ($now+70) "finding" "Ελληνικά — δοκιμή ✓" "scratch" $null
    $ctx = Ctx (Invoke-Hook $sidA)
    Assert "T7-unicode-stdout" ($ctx -match "Ελληνικά" -and $ctx -match "δοκιμή") "unicode must survive: got [$ctx]"

    # T9: 3-session fan-in — C joins, writes; A sees C and B lines together
    Set-Content (Join-Path $bus "_sessions\$sidC") $task -NoNewline
    Bus-Line $sidC ($now+80) "claim" "lane-c-work" "scratch" "lane-c"
    Bus-Line $sidB ($now+81) "done" "b-finished" "promoted" $null
    $ctx = Ctx (Invoke-Hook $sidA)
    Assert "T9-fanin" ($ctx -match "lane-c-work" -and $ctx -match "b-finished") "A sees both B and C"
    Assert "T9b-lane-shown" ($ctx -match "\[lane-c\]") "lane must be shown in brackets"

    # T10: corrupt watermark -> replay (no crash), all lines re-surface
    Set-Content (Join-Path $td "watermark.$sidA.json") 'CORRUPT{{{' -Encoding UTF8
    $ctx = Ctx (Invoke-Hook $sidA)
    Assert "T10-corrupt-watermark-replays" ($ctx -match "B-found-the-thing" -and $ctx -notmatch "PARSE-ERROR") "corrupt wm must degrade to full replay"

    # T12: empty bus file for a paired session doesn't crash others
    Set-Content (Join-Path $td "bus.$sidC.jsonl") '' -Encoding UTF8
    Bus-Line $sidB ($now+100) "note" "after-empty-file" "promoted" $null
    $ctx = Ctx (Invoke-Hook $sidA)
    Assert "T12-empty-busfile-ok" ($ctx -match "after-empty-file") "empty peer file must not break read"

    # T13: overlong line text is truncated to ~300 chars
    Bus-Line $sidB ($now+200) "note" ("L" * 900) "promoted" $null
    $ctx = Ctx (Invoke-Hook $sidA)
    Assert "T13-line-truncated" ($ctx -match "\[truncated\]" -and $ctx -notmatch ("L" * 400)) "900-char text must be capped"

    # T14: >20 new lines -> only newest 20 shown, header notes the drop
    for ($i = 1; $i -le 30; $i++) { Bus-Line $sidB ($now+300+$i) "note" "flood-$i" "promoted" $null }
    $ctx = Ctx (Invoke-Hook $sidA)
    Assert "T14-line-cap" ($ctx -match "flood-30" -and $ctx -notmatch '"?flood-1"?\b' -and $ctx -match "showing newest 20") "flood capped at newest 20 with notice"
}
finally {
    # --- teardown: remove ONLY sandbox artifacts ---
    Remove-Item -LiteralPath $td -Recurse -Force -EA SilentlyContinue
    foreach ($s in @($sidA, $sidB, $sidC, "testsess-unpaired-000")) {
        Remove-Item -LiteralPath (Join-Path $bus "_sessions\$s") -Force -EA SilentlyContinue
    }
}

$fails = @($results | Where-Object { -not $_.pass })
$stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$summary = "live-bus-test $stamp : {0}/{1} passed" -f (@($results | Where-Object pass).Count), $results.Count
$body = ($results | ForEach-Object { "{0} {1} - {2}" -f ($(if ($_.pass) {"PASS"} else {"FAIL"})), $_.name, $_.detail }) -join "`r`n"
[System.IO.File]::WriteAllText($log, "$summary`r`n$body`r`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "`n$summary"
if ($fails.Count) { exit 1 } else { exit 0 }
