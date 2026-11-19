import { spawn, execFileSync, type ChildProcess } from "node:child_process"
import { appendFileSync, closeSync, existsSync, openSync, readdirSync, readFileSync } from "node:fs"
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
 * Start serve-up.ps1 without waiting for it. Its output is appended to
 * logs/serve-up.log so pre-spawn failures (missing binaries, no GGUF, missing
 * models.json entry) are diagnosable instead of vanishing. The child lives as
 * long as the process hosting this plugin; OpenCode reaps it on exit, which is
 * the desired teardown behavior. `detached: true` is deliberately NOT used: on
 * Windows it creates a console-less child that silently fails.
 */
export function spawnServer(cfg: LocalLlamaConfig): ChildProcess | null {
  const script = kitScript(cfg, "serve-up.ps1")
  debug(`spawn ${PS} ${script}`)
  try {
    const log = openSync(path.join(cfg.kitPath!, "logs", "serve-up.log"), "a")
    const child = spawn(PS, [...PS_ARGS, script], {
      stdio: ["ignore", log, log],
      windowsHide: true,
    })
    child.on("exit", (code) => {
      closeSync(log)
      debug(`spawn exit: ${code}`)
    })
    child.on("error", (error) => {
      closeSync(log)
      debug(`spawn error: ${error.message}`)
    })
    child.unref()
    return child
  } catch (error) {
    debug(`spawn threw: ${(error as Error).message}`)
    return null
  }
}

/** Last lines of the serve-up log, used when the launcher dies early. */
export function readServeUpLog(cfg: LocalLlamaConfig, lines = 15): string {
  try {
    const content = readFileSync(path.join(cfg.kitPath!, "logs", "serve-up.log"), "utf8")
    return content.split(/\r?\n/).filter(Boolean).slice(-lines).join("\n")
  } catch {
    return ""
  }
}

/** Resolve the models folder the kit will use (kit config.json, kit-relative). */
export function resolveModelsDir(cfg: LocalLlamaConfig): string {
  try {
    const kitConfig = JSON.parse(readFileSync(path.join(cfg.kitPath!, "config.json"), "utf8")) as {
      modelsDir?: string
    }
    if (!kitConfig.modelsDir) return path.join(cfg.kitPath!, "models")
    return path.isAbsolute(kitConfig.modelsDir)
      ? kitConfig.modelsDir
      : path.join(cfg.kitPath!, kitConfig.modelsDir)
  } catch {
    return path.join(cfg.kitPath!, "models")
  }
}

function findServerExe(dir: string): string | null {
  if (!existsSync(dir)) return null
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      const nested = findServerExe(full)
      if (nested) return nested
    } else if (entry.name.toLowerCase() === "llama-server.exe") {
      return full
    }
  }
  return null
}

/**
 * Cheap checks before spawning, so a misconfigured kit fails in milliseconds
 * with an actionable message instead of timing out after startTimeoutMs.
 */
export function preflight(cfg: LocalLlamaConfig): string | null {
  let toolsDir = cfg.binPath ?? path.join(cfg.kitPath!, "build", "tools")
  try {
    const kitConfig = JSON.parse(readFileSync(path.join(cfg.kitPath!, "config.json"), "utf8")) as {
      toolsDir?: string
    }
    if (!cfg.binPath && kitConfig.toolsDir) {
      toolsDir = path.isAbsolute(kitConfig.toolsDir)
        ? kitConfig.toolsDir
        : path.join(cfg.kitPath!, kitConfig.toolsDir)
    }
  } catch {
    // fall back to the default location
  }

  if (!findServerExe(toolsDir)) {
    return `llama-server.exe not found under ${toolsDir}. Run the kit's fetch.ps1 to install llama.cpp.`
  }

  const modelsDir = resolveModelsDir(cfg)
  const ggufs = existsSync(modelsDir)
    ? readdirSync(modelsDir).filter((f) => f.toLowerCase().endsWith(".gguf"))
    : []
  if (ggufs.length === 0) {
    return `no .gguf files in ${modelsDir}. Add a model and an entry in models.json.`
  }
  return null
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

/** Resolve once /health answers; fail early if the launcher exits or is killed. */
export async function waitForHealth(
  cfg: LocalLlamaConfig,
  timeoutMs: number,
  isAlive?: () => boolean,
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (isAlive && !isAlive()) {
      const tail = readServeUpLog(cfg)
      throw new Error(
        `serve-up.ps1 exited before the server became healthy.${tail ? `\n${tail}` : ""}`,
      )
    }
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
