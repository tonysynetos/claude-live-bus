# Self-test for live-bus v2 (Tier 0 + Tier 1). Runs in an isolated _selftest task so a
# real pairing is untouched. Re-run after ANY change to live-bus-read/commit.
#   Tier 0: at-least-once delivery, priority eviction, unpaired fast path
#   Tier 1: PreToolUse mid-turn delivery, no in-turn repeats, open-lane replay,
#           stale-claim flagging, evidence-gated promotion, peekmark fast path

$ErrorActionPreference = 'Stop'
$bus    = "$env:USERPROFILE\.claude\live-bus"
$TASK   = "_selftest"
$ME     = "TESTSID-1111"
$PEER   = "PEERSID-2222"
$GHOST  = "GHOSTSID-3333"
$td     = "$bus\$TASK"
$readHk = "$env:USERPROFILE\.claude\hooks\live-bus-read.ps1"
$cmtHk  = "$env:USERPROFILE\.claude\hooks\live-bus-commit.ps1"
$pass = 0; $fail = 0
function Check($name, $cond) {
  if ($cond) { Write-Host "  PASS  $name"; $script:pass++ }
  else       { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:fail++ }
}
function ReadPrompt { ('{"session_id":"' + $ME + '"}') | & powershell -NoProfile -File $readHk }
function ReadTool   { ('{"session_id":"' + $ME + '"}') | & powershell -NoProfile -File $readHk -Mode tool }
function Commit     { ('{"session_id":"' + $ME + '"}') | & powershell -NoProfile -File $cmtHk }

Remove-Item $td -Recurse -Force -EA SilentlyContinue
New-Item -ItemType Directory -Force -Path $td, "$bus\_sessions" | Out-Null
Set-Content "$bus\_sessions\$ME" $TASK -NoNewline

$now = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$t0  = $now - 3600000
function Line($sess, $kind, $text, $ts, $lane, $tier, $ev) {
  $o = @{ session=$sess; ts=$ts; kind=$kind; text=$text; tier=$tier }
  if ($lane) { $o.lane = $lane }
  if ($ev)   { $o.evidence = $ev }
  ($o | ConvertTo-Json -Compress) | Add-Content "$td\bus.$sess.jsonl"
  Start-Sleep -Milliseconds 12   # ensure file mtime advances for the peek gate
}

Line $PEER "claim"   "editing crm.campaigns schema"   ($t0+1) "schema" "scratch" $null
Line $PEER "finding" "campaigns table does not exist" ($t0+2) $null     "scratch" $null

Write-Host "`n[1] Tier 0 -- prompt read, pending only, at-least-once on cancel"
$o1 = ReadPrompt
Check "surfaces the peer lines"          ($o1 -match "campaigns table")
Check "pending written"                  (Test-Path "$td\watermark.pending.$ME.json")
Check "committed NOT written"            (-not (Test-Path "$td\watermark.$ME.json"))
$o2 = ReadPrompt
Check "cancelled turn re-surfaces lines" ($o2 -match "campaigns table")
Commit | Out-Null
Check "commit promotes pending"          ((Test-Path "$td\watermark.$ME.json") -and -not (Test-Path "$td\watermark.pending.$ME.json"))
Check "consumed lines do not repeat"     (-not (ReadPrompt))

Write-Host "`n[2] Tier 1 -- PreToolUse delivers MID-TURN (Tier 0 went deaf here)"
Line $PEER "finding" "found the root cause in reservation.ts" ($now-5000) $null "scratch" $null
$t1 = ReadTool
Check "tool mode surfaces new line"      ($t1 -match "root cause")
Check "tagged as mid-turn"               ($t1 -match "mid-turn")
Check "emits PreToolUse event name"      ($t1 -match "PreToolUse")

Write-Host "`n[3] Tier 1 -- no repeats across tool calls inside one turn"
Check "2nd tool call silent"             (-not (ReadTool))
Check "3rd tool call silent"             (-not (ReadTool))

Write-Host "`n[4] Tier 1 -- peekmark fast path"
Check "peekmark written"                 (Test-Path "$td\peekmark.$ME.json")

Write-Host "`n[5] Tier 1 -- evidence-gated promotion"
Line $PEER "finding" "tests pass on the fix" ($now-4000) $null "promoted" "commit 186f58c"
Line $PEER "finding" "this one is a hunch"   ($now-3000) $null "promoted" $null
$t5 = ReadTool
Check "evidence-backed shows [verified:]" ($t5 -match "verified: commit 186f58c")
Check "evidence-free is DEMOTED"          ($t5 -match "hunch" -and $t5 -match "carried no evidence")

Write-Host "`n[6] Tier 1 -- open lanes replayed; done releases"
Check "open lane shown"                   ($t5 -match "OPEN LANES" -and $t5 -match "\[schema\]")
Line $PEER "done" "schema work finished" ($now-2000) "schema" "scratch" $null
$t6 = ReadTool
Check "done releases the lane"            ($t6 -notmatch "OPEN LANES")

Write-Host "`n[7] Tier 1 -- stale claim from a session that never checked in"
Line $GHOST "claim" "owns the campaign UI" ($now-1500) "ui" "scratch" $null
$t7 = ReadTool
Check "ghost lane shown"                  ($t7 -match "\[ui\]")
Check "flagged STALE"                     ($t7 -match "STALE")

Write-Host "`n[8] Unpaired sessions stay silent (this runs on EVERY tool call)"
Check "prompt mode silent"  (-not ('{"session_id":"NOPE-9999"}' | & powershell -NoProfile -File $readHk))
Check "tool mode silent"    (-not ('{"session_id":"NOPE-9999"}' | & powershell -NoProfile -File $readHk -Mode tool))
Check "commit mode silent"  (-not ('{"session_id":"NOPE-9999"}' | & powershell -NoProfile -File $cmtHk))

Write-Host "`n[9] Tier 0 regression -- priority eviction keeps an OLD claim"
Remove-Item "$td\watermark.$ME.json","$td\watermark.pending.$ME.json","$td\peekmark.$ME.json" -Force -EA SilentlyContinue
Line $PEER "claim" "critical lane nobody must touch" ($now-1400) "critical" "scratch" $null
foreach ($i in 1..25) {
  (@{ session=$PEER; ts=($now-1400+$i); kind="note"; text="chatter $i"; tier="scratch" } | ConvertTo-Json -Compress) |
    Add-Content "$td\bus.$PEER.jsonl"
}
$t9 = ReadPrompt
Check "old claim survived eviction"       ($t9 -match "critical lane nobody")
Check "eviction reported"                 ($t9 -match "held back")
Check "capped at 20 shown lines"          ((([regex]::Matches($t9, "  - PEERSID")).Count) -le 20)

Write-Host "`n[10] Tier 1 -- Node PreToolUse gate (runs on EVERY tool call)"
$node = "C:\Program Files\nodejs\node.exe"
$gate = "$env:USERPROFILE\.claude\hooks\live-bus-peek.mjs"
if ((Test-Path $node) -and (Test-Path $gate)) {
  Get-ChildItem $td -Exclude "bus.*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
  Start-Sleep -Milliseconds 30
  (@{ session=$PEER; ts=[long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()); kind="finding"; text="delivered through the gate"; tier="scratch" } |
    ConvertTo-Json -Compress) | Add-Content "$td\bus.$PEER.jsonl"
  Check "gate delegates when new"   ((('{"session_id":"' + $ME + '"}') | & $node $gate) -match "delivered through the gate")
  Check "gate silent when nothing"  (-not (('{"session_id":"' + $ME + '"}') | & $node $gate))
  Check "gate silent when unpaired" (-not ('{"session_id":"NOPE-9999"}' | & $node $gate))
  # Both BOM traps: PS writes UTF8-with-BOM, and JSON.parse rejects a BOM. If either
  # strip regresses, the gate delegates on every call (~570ms) instead of ~62ms.
  $t = (Measure-Command { 1..10 | ForEach-Object { ('{"session_id":"' + $ME + '"}') | & $node $gate | Out-Null } }).TotalMilliseconds / 10
  Check "idle gate stays cheap (<150ms, got $([int]$t)ms)" ($t -lt 150)
} else { Write-Host "  SKIP  node or gate not found" }

Write-Host "`n[11] Autonomy -- the WRITE side (live-bus-post.ps1)"
$post = "$env:USERPROFILE\.claude\hooks\live-bus-post.ps1"
if (Test-Path $post) {
  $busFile = "$td\bus.$ME.jsonl"
  # NOTE: always @()-wrap Get-Content here. On a one-line file it returns a STRING, and
  # [-1] then indexes the last CHARACTER instead of the last line.
  Check "happy path confirms"      ((& $post -Sid $ME -Kind claim -Lane "lanA" -Text "taking lane A") -match "posted to")
  $j = @(Get-Content $busFile)[-1] | ConvertFrom-Json
  Check "kind+lane recorded"       ($j.kind -eq "claim" -and $j.lane -eq "lanA")
  Check "defaults provisional"     ($j.tier -eq "scratch")
  & $post -Sid $ME -Kind finding -Text "verified thing" -Evidence "sha123" | Out-Null
  $j2 = @(Get-Content $busFile)[-1] | ConvertFrom-Json
  Check "evidence promotes"        ($j2.tier -eq "promoted" -and $j2.evidence -eq "sha123")
  # Guards: assert the OUTCOME (nothing written), not the error text — PS wraps native
  # stderr in an ErrorRecord and string-matching it is unreliable.
  $n = @(Get-Content $busFile).Count
  & $post -Sid $ME -Kind note -Text ([string]::new('x',700)) -EA SilentlyContinue | Out-Null
  Check "over-long line refused"   (@(Get-Content $busFile).Count -eq $n)
  try { & $post -Sid $ME -Kind bogus -Text "x" -EA Stop | Out-Null } catch {}
  Check "invalid kind refused"     (@(Get-Content $busFile).Count -eq $n)
  & $post -Sid "UNPAIRED-0000" -Kind note -Text "orphan" -EA SilentlyContinue | Out-Null
  Check "unpaired sid refused"     (-not (Test-Path "$td\bus.UNPAIRED-0000.jsonl"))
} else { Write-Host "  SKIP  live-bus-post.ps1 not found" }

Write-Host "`n[12] Autonomy -- the footer actually instructs the receiver to post"
Remove-Item "$td\watermark.$ME.json","$td\watermark.pending.$ME.json","$td\peekmark.$ME.json" -Force -EA SilentlyContinue
(@{ session=$PEER; ts=[long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()); kind="note"; text="footer probe"; tier="scratch" } |
  ConvertTo-Json -Compress) | Add-Content "$td\bus.$PEER.jsonl"
$f = ReadPrompt
Check "names the write protocol"  ($f -match "YOUR side of the protocol")
Check "carries the post command"  ($f -match "live-bus-post.ps1")
Check "carries the anti-loop rule"($f -match "Never post in reaction")
Check "warns off held lanes"      ($f -match "Do NOT start a lane listed above")

Remove-Item $td -Recurse -Force -EA SilentlyContinue
Remove-Item "$bus\_sessions\$ME" -Force -EA SilentlyContinue
Write-Host "`n================ $pass passed, $fail failed ================"
if ($fail -gt 0) { exit 1 }
