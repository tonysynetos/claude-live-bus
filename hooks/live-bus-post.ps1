param(
  [Parameter(Mandatory=$true)][string]$Sid,
  [Parameter(Mandatory=$true)][ValidateSet('claim','done','finding','note','leave')][string]$Kind,
  [Parameter(Mandatory=$true)][string]$Text,
  [string]$Lane = "",
  [string]$Evidence = ""
)

# Writer for the live-bus. Exists so a SESSION can post without the user typing /bus:
# the autonomous protocol in commands/pair.md needs posting to be one short, hard-to-
# get-wrong command, not six lines of inline PowerShell per claim.
#
# Enforces at the write boundary what the reader would otherwise have to forgive:
#   - the session must actually be paired (a line written to an unpaired task is lost)
#   - one line, <=600 chars (the reader truncates past that)
#   - tier:promoted ONLY with evidence (the reader demotes it anyway — fail loudly here)
#   - one-writer-per-file: a session may only ever append to bus.<its own sid>.jsonl

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$busRoot = Join-Path $env:USERPROFILE ".claude\live-bus"
$ptr = Join-Path $busRoot "_sessions\$Sid"
if (-not (Test-Path $ptr)) {
  Write-Output "NOT PAIRED - this session ($Sid) has no live-bus pointer. Run /pair <task-id> first; nothing was written."
  exit 1
}
$task = (Get-Content $ptr -Raw).Trim()
$taskDir = Join-Path $busRoot $task
if (-not (Test-Path $taskDir)) {
  Write-Output "NOT PAIRED - task dir '$task' is gone (purged?). Nothing was written."
  exit 1
}

$Text = ($Text -replace '\s+', ' ').Trim()
if ($Text.Length -gt 600) {
  Write-Output "TOO LONG - $($Text.Length) chars; the reader truncates at 600. Split this into several short lines. Nothing was written."
  exit 1
}
if (-not $Text) { Write-Output "EMPTY - nothing was written."; exit 1 }

$tier = "scratch"
if ($Evidence) { $tier = "promoted" }

$ts = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$obj = @{ session = $Sid; ts = $ts; kind = $Kind; text = $Text; tier = $tier }
if ($Lane)     { $obj.lane = $Lane }
if ($Evidence) { $obj.evidence = $Evidence }

($obj | ConvertTo-Json -Compress) | Add-Content (Join-Path $taskDir "bus.$Sid.jsonl") -Encoding UTF8

$laneStr = if ($Lane) { " [$Lane]" } else { "" }
$tierStr = if ($Evidence) { " (verified: $Evidence)" } else { "" }
Write-Output "posted to '$task': $Kind$laneStr$tierStr"
exit 0
