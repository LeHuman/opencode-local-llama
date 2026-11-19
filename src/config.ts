/**
 * Plugin options, with defaults. All fields are read from the `options` object
 * of the plugin entry in opencode.json(c).
 */
export interface ModelMeta {
  /** Display name shown in the model picker. */
  name?: string
  /** Context window advertised to OpenCode. */
  context?: number
  /** Max output tokens advertised to OpenCode. */
  output?: number
}

export interface LocalLlamaConfig {
  /** Existing kit folder. Omit to let the plugin scaffold one. */
  kitPath?: string
  /** Where the scaffolded kit lives. Default: %LOCALAPPDATA%\opencode-local-llama. */
  dataDir?: string
  /** Folder containing llama-server.exe. Written to the kit's config.json. */
  binPath?: string
  /** Folder containing GGUFs. Written to the kit's config.json. */
  modelsPath?: string
  host: string
  port: number
  baseURL: string
  providerID: string
  providerName: string
  /** How long to wait for /health after spawning serve-up.ps1. */
  startTimeoutMs: number
  /** Context window used for models without explicit metadata. */
  defaultContext: number
  /** Max output tokens used for models without explicit metadata. */
  defaultOutput: number
  /** Per-model metadata overrides, keyed by the model id llama-server reports. */
  models: Record<string, ModelMeta>
  supervise: boolean
  /** Consecutive failed restarts before entering cooldown. */
  maxRestarts: number
  /** Time to wait before attempting restarts again after maxRestarts failures. */
  cooldownMs: number
  /** Backoff between restart attempts, in ms. Last value is reused. */
  restartBackoffMs: number[]
  /** Stop the server on plugin dispose (only if the plugin started it). */
  teardownOnExit: boolean
  /** Model ids to register if GET /v1/models is unavailable. */
  fallbackModels: string[]
  /** Append lifecycle traces to %TEMP%\opencode-local-llama.log. */
  debug: boolean
}

const DEFAULTS = {
  host: "127.0.0.1",
  port: 5514,
  providerID: "local-llama",
  providerName: "Local llama.cpp",
  startTimeoutMs: 180_000,
  defaultContext: 65_536,
  defaultOutput: 16_384,
  models: {},
  supervise: true,
  maxRestarts: 3,
  cooldownMs: 10 * 60_000,
  restartBackoffMs: [5_000, 30_000, 60_000],
  teardownOnExit: true,
  fallbackModels: [],
  debug: false,
}

function num(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : fallback
}

const str = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined

export function readConfig(options: Record<string, unknown>): LocalLlamaConfig {
  const host = typeof options.host === "string" && options.host ? options.host : DEFAULTS.host
  const port = num(options.port, DEFAULTS.port)
  return {
    kitPath: str(options.kitPath),
    dataDir: str(options.dataDir),
    binPath: str(options.binPath),
    modelsPath: str(options.modelsPath),
    host,
    port,
    baseURL: `http://${host}:${port}`,
    providerID: typeof options.providerID === "string" && options.providerID ? options.providerID : DEFAULTS.providerID,
    providerName:
      typeof options.providerName === "string" && options.providerName ? options.providerName : DEFAULTS.providerName,
    startTimeoutMs: num(options.startTimeoutMs, DEFAULTS.startTimeoutMs),
    defaultContext: num(options.defaultContext, DEFAULTS.defaultContext),
    defaultOutput: num(options.defaultOutput, DEFAULTS.defaultOutput),
    models: (options.models as Record<string, ModelMeta>) ?? DEFAULTS.models,
    supervise: options.supervise !== false,
    maxRestarts: num(options.maxRestarts, DEFAULTS.maxRestarts),
    cooldownMs: num(options.cooldownMs, DEFAULTS.cooldownMs),
    restartBackoffMs: Array.isArray(options.restartBackoffMs)
      ? (options.restartBackoffMs as number[])
      : DEFAULTS.restartBackoffMs,
    teardownOnExit: options.teardownOnExit !== false,
    fallbackModels: Array.isArray(options.fallbackModels)
      ? (options.fallbackModels as string[])
      : DEFAULTS.fallbackModels,
    debug: options.debug === true,
  }
}
