import type { LocalLlamaConfig } from "./config"
import { isHealthy, readErrorLog, spawnServer } from "./kit"

export interface SupervisorOptions {
  /** Called whenever the supervisor spawns a new server process. */
  onSpawn?: () => void
  /** Log sink; defaults to console.log. */
  log?: (message: string) => void
}

export interface Supervisor {
  stop(): void
}

const TICK_MS = 15_000
const OOM_PATTERN = /out of memory|cudaMalloc failed|failed to allocate|cudaErrorMemoryAllocation|CUDA error/i

/**
 * Watches the server while OpenCode runs. On a crash it restarts with
 * escalating backoff; OOM is deterministic, so it enters cooldown immediately
 * instead of burning retries on a config that cannot fit.
 */
export function startSupervisor(cfg: LocalLlamaConfig, options: SupervisorOptions = {}): Supervisor {
  const log = options.log ?? ((message: string) => console.log(`[local-llama] ${message}`))
  let failures = 0
  let pending: ReturnType<typeof setTimeout> | null = null
  let cooldownUntil = 0
  let stopped = false

  const tick = async () => {
    if (stopped || pending) return
    if (Date.now() < cooldownUntil) return

    if (await isHealthy(cfg)) {
      if (failures > 0) log("server is healthy again")
      failures = 0
      return
    }

    const tail = readErrorLog(cfg)
    if (OOM_PATTERN.test(tail)) {
      cooldownUntil = Date.now() + cfg.cooldownMs
      failures = 0
      log(
        "server crashed with a GPU/OOM error — not retrying (the config cannot fit). " +
          `Lower the context for this model in models.json. Cooldown ${Math.round(cfg.cooldownMs / 60_000)} min.`,
      )
      return
    }

    if (failures >= cfg.maxRestarts) {
      cooldownUntil = Date.now() + cfg.cooldownMs
      failures = 0
      log(
        `gave up after ${cfg.maxRestarts} restart attempts; cooling down for ` +
          `${Math.round(cfg.cooldownMs / 60_000)} min.`,
      )
      return
    }

    const delay = cfg.restartBackoffMs[Math.min(failures, cfg.restartBackoffMs.length - 1)]
    failures += 1
    log(`server is down — restart attempt ${failures}/${cfg.maxRestarts} in ${Math.round(delay / 1000)}s`)
    pending = setTimeout(() => {
      pending = null
      if (stopped) return
      options.onSpawn?.()
      spawnServer(cfg)
    }, delay)
  }

  const timer = setInterval(() => void tick(), TICK_MS)

  return {
    stop() {
      stopped = true
      clearInterval(timer)
      if (pending) {
        clearTimeout(pending)
        pending = null
      }
    },
  }
}
