import { spawn, execFileSync } from "node:child_process"
import { appendFileSync, existsSync, readFileSync } from "node:fs"
import path from "node:path"
import type { LocalLlamaConfig } from "./config"

const DEBUG_FILE = path.join(process.env.TEMP ?? ".", "opencode-local-llama.log")
let debugEnabled = false

/** Enable/disable lifecycle tracing to %TEMP%\opencode-local-llama.log. */
export function setDebug(enabled: boolean): void {
  debugEnabled = enabled
}

export function debug(message: string): void {
  if (!debugEnabled) return
  try {
    appendFileSync(DEBUG_FILE, `${new Date().toISOString()} ${message}\n`)
  } catch {
    // debugging must never break the plugin
  }
}

/** The kit is Windows-only today: its lifecycle scripts are PowerShell. */
export function assertPlatform(): void {
  if (process.platform !== "win32") {
    throw new Error("opencode-local-llama currently requires Windows (the kit ships PowerShell scripts)")
  }
}

export function kitScript(cfg: LocalLlamaConfig, name: string): string {
  return path.join(cfg.kitPath!, "scripts", name)
}

export function kitReady(cfg: LocalLlamaConfig): boolean {
  return existsSync(kitScript(cfg, "serve-up.ps1")) && existsSync(kitScript(cfg, "serve-down.ps1"))
}

const PS = `${process.env.SystemRoot ?? "C:\\Windows"}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`
const PS_ARGS = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]

/**
 * Start serve-up.ps1 without waiting for it. The child lives as long as the
 * process hosting this plugin; OpenCode reaps it on exit, which is the desired
 * teardown behavior. `detached: true` is deliberately NOT used: on Windows it
 * creates a console-less child that silently fails.
 */
export function spawnServer(cfg: LocalLlamaConfig): void {
  const script = kitScript(cfg, "serve-up.ps1")
  debug(`spawn ${PS} ${script}`)
  try {
    const child = spawn(PS, [...PS_ARGS, script], {
      stdio: "ignore",
      windowsHide: true,
    })
    child.on("error", (error) => debug(`spawn error: ${error.message}`))
    child.on("exit", (code) => debug(`spawn exit: ${code}`))
    child.unref()
  } catch (error) {
    debug(`spawn threw: ${(error as Error).message}`)
  }
}

/** Stop the server and wait for serve-down.ps1; never throws. */
export function stopServer(cfg: LocalLlamaConfig): void {
  try {
    debug("stop: serve-down.ps1")
    execFileSync(PS, [...PS_ARGS, kitScript(cfg, "serve-down.ps1")], {
      timeout: 60_000,
      stdio: "ignore",
      windowsHide: true,
    })
  } catch {
    // Best effort: an already-dead server or a stale pid file is not an error.
  }
}

/**
 * Guard against OpenCode exiting without running plugin cleanup (hard exit,
 * crash, or a CLI that does not await dispose). A detached PowerShell waits for
 * `parentPid` to disappear, then runs serve-down.ps1.
 */
export function spawnWatchdog(cfg: LocalLlamaConfig, parentPid: number): void {
  const inner = [
    `$parent = ${parentPid}`,
    "while (Get-Process -Id $parent -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 2 }",
    `& '${kitScript(cfg, "serve-down.ps1").replace(/'/g, "''")}'`,
  ].join("\n")
  const innerEncoded = Buffer.from(inner, "utf16le").toString("base64")
  // Launch through Start-Process so the watchdog is orphaned: a direct child is
  // killed together with OpenCode, which defeats the purpose.
  const outer = [
    `Start-Process -FilePath '${PS}' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand','${innerEncoded}' -WindowStyle Hidden`,
  ].join("\n")
  const outerEncoded = Buffer.from(outer, "utf16le").toString("base64")
  debug(`watchdog for parent ${parentPid}`)
  try {
    const child = spawn(PS, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", outerEncoded], {
      stdio: "ignore",
      windowsHide: true,
    })
    child.on("error", (error) => debug(`watchdog error: ${error.message}`))
    child.unref()
  } catch (error) {
    debug(`watchdog threw: ${(error as Error).message}`)
  }
}

/** GET /health — outside /v1, returns 200 once the model is loaded. */
export async function isHealthy(cfg: LocalLlamaConfig, timeoutMs = 2_000): Promise<boolean> {
  try {
    const res = await fetch(`${cfg.baseURL}/health`, { signal: AbortSignal.timeout(timeoutMs) })
    return res.ok
  } catch {
    return false
  }
}

/** Resolve once /health answers, reject on timeout. */
export async function waitForHealth(cfg: LocalLlamaConfig, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await isHealthy(cfg)) return
    await new Promise((resolve) => setTimeout(resolve, 1_000))
  }
  throw new Error(
    `llama-server did not become healthy within ${Math.round(timeoutMs / 1000)}s (${cfg.baseURL}/health)`,
  )
}

export interface DiscoveredModel {
  /** Model id callers use (alias when the kit provides one). */
  id: string
  /** Context window the server actually launched the model with, when known. */
  context?: number
}

/** Read `--ctx-size`/`-c` out of the router's per-model launch args. */
function contextFromArgs(args: unknown): number | undefined {
  if (!Array.isArray(args)) return undefined
  for (let i = 0; i < args.length - 1; i++) {
    const flag = String(args[i])
    if (flag === "--ctx-size" || flag === "-c") {
      const value = Number(args[i + 1])
      if (Number.isFinite(value) && value > 0) return value
    }
  }
  return undefined
}

/**
 * Models exposed by llama-server. Router mode lists every GGUF in the kit's
 * models directory; a configured alias (e.g. `My-Model`) is preferred so
 * callers keep stable names instead of GGUF file stems.
 */
export async function discoverModels(cfg: LocalLlamaConfig): Promise<DiscoveredModel[]> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 5_000)
  try {
    const res = await fetch(`${cfg.baseURL}/v1/models`, { signal: controller.signal })
    if (!res.ok) throw new Error(`GET /v1/models -> HTTP ${res.status}`)
    const payload = (await res.json()) as {
      data?: Array<{
        id?: string
        aliases?: string[]
        status?: { args?: unknown; preset?: string }
        context_length?: number
      }>
    }
    const seen = new Map<string, DiscoveredModel>()
    for (const entry of payload?.data ?? []) {
      const id = entry?.aliases?.[0] ?? entry?.id
      if (typeof id !== "string" || id.length === 0) continue
      const context = contextFromArgs(entry?.status?.args)
      if (!seen.has(id)) seen.set(id, { id, context })
      else if (context && !seen.get(id)!.context) seen.get(id)!.context = context
    }
    return [...seen.values()]
  } finally {
    clearTimeout(timer)
  }
}

/** Tail of the kit's stderr log, used for OOM detection. */
export function readErrorLog(cfg: LocalLlamaConfig, lines = 40): string {
  try {
    const content = readFileSync(path.join(cfg.kitPath!, "logs", "server.err.log"), "utf8")
    return content.split(/\r?\n/).slice(-lines).join("\n")
  } catch {
    return ""
  }
}
