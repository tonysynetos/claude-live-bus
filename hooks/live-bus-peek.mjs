// PreToolUse gate for the live-bus (v2 Tier 1). Runs on EVERY tool call, so its only
// job is to be cheap and to answer one question: could anything possibly be new?
//
// WHY THIS EXISTS AT ALL: mid-turn delivery needs a PreToolUse hook with matcher "*",
// and a PowerShell hook there measured 339 ms per tool call — a tax every solo session
// pays forever for a feature that helps only paired ones. Node's process launch is
// ~52 ms, and this gate adds ~10 ms on top. Measured 2026-08-03:
//   PowerShell unpaired 339 ms  |  bare pwsh 190 ms  |  node gate 62 ms  |  bare node 52 ms
//
// DELIBERATELY CONTAINS NO BUS LOGIC. Watermarks, claim replay, eviction and evidence
// rules live in live-bus-read.ps1 and must stay there — this file would otherwise be a
// second implementation to drift out of sync. It decides only "run the reader or not",
// and it never writes the peekmark (the reader owns that; writing it here would swallow
// the very notification we are gating for).

import { existsSync, readFileSync, readdirSync, statSync } from 'fs'
import { join } from 'path'
import { spawn } from 'child_process'

const bail = () => process.exit(0)

let raw = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', (c) => (raw += c))
process.stdin.on('end', () => {
  let sid
  // Strip a leading BOM before parsing. Claude Code sends clean JSON, but anything
  // piping in from PowerShell prepends one, and JSON.parse rejects it — which fails
  // CLOSED (silently no delivery) and cost an hour to find once already.
  try { sid = JSON.parse(raw.replace(/^﻿/, '').trim()).session_id } catch { return bail() }
  if (!sid) return bail()

  const busRoot = join(process.env.USERPROFILE || '', '.claude', 'live-bus')
  const ptr = join(busRoot, '_sessions', sid)
  if (!existsSync(ptr)) return bail()          // not paired -> the 99% case, one stat

  let task
  try { task = readFileSync(ptr, 'utf8').trim() } catch { return bail() }
  if (!task) return bail()
  const taskDir = join(busRoot, task)
  if (!existsSync(taskDir)) return bail()

  // Newest peer-file mtime vs our peekmark. Appends bump mtime, so this is enough to
  // know whether the (expensive) reader could have anything to say.
  let newest = 0
  try {
    for (const f of readdirSync(taskDir)) {
      if (!f.startsWith('bus.') || !f.endsWith('.jsonl')) continue
      if (f === `bus.${sid}.jsonl`) continue   // my own writes are not news
      const m = statSync(join(taskDir, f)).mtimeMs
      if (m > newest) newest = m
    }
  } catch { return bail() }
  if (newest === 0) return bail()

  // Same BOM trap as the stdin parse above, and nastier: PowerShell's `-Encoding UTF8`
  // is UTF8-WITH-BOM in 5.1, so the reader's own peekmark is BOM-prefixed. Without the
  // strip, this parse throws, peek falls back to 0, and the gate delegates on EVERY
  // tool call — measured 566 ms/call, worse than having no gate at all.
  let peek = 0
  try {
    const rawPeek = readFileSync(join(taskDir, `peekmark.${sid}.json`), 'utf8').replace(/^﻿/, '')
    peek = JSON.parse(rawPeek).ticks || 0
  } catch {}
  // The reader stores .NET ticks (100 ns since year 1); convert to compare with mtimeMs.
  const peekMs = peek > 0 ? peek / 10000 - 62135596800000 : 0
  if (newest <= peekMs + 1) return bail()      // 1 ms slack for clock granularity

  // Something is genuinely new — now, and only now, pay for PowerShell.
  // Must be "powershell.exe": Node's spawn searches PATH but not PATHEXT, so the
  // bare name fails ENOENT on Windows and this gate would silently never deliver.
  const ps = spawn('powershell.exe', [
    '-NoProfile', '-File',
    join(process.env.USERPROFILE || '', '.claude', 'hooks', 'live-bus-read.ps1'),
    '-Mode', 'tool',
  ], { stdio: ['pipe', 'inherit', 'ignore'] })
  ps.on('error', bail)
  ps.on('close', () => process.exit(0))
  ps.stdin.write(raw)
  ps.stdin.end()
})
