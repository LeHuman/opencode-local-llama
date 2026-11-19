import { Plugin } from "@opencode/plugin"
import { readConfig, type LocalLlamaConfig } from "./config"
import {
  assertPlatform,
  debug,
  discoverModels,
  isHealthy,
  kitReady,
  preflight,
  setDebug,
  spawnServer,
  spawnWatchdog,
  stopServer,
  waitForHealth,
  type DiscoveredModel,
} from "./kit"
import { providerRegistration } from "./models"
import { readConfiguredModels, resolveKit } from "./scaffold"
import { startSupervisor } from "./supervisor"

const TAG = "[local-llama]"

/**
 * Boots the local llama.cpp server when OpenCode starts, registers the models it
 * serves, supervises crashes, and tears the server down when the hosting process
 * exits.
 *
 * Activation never blocks and never throws: a broken kit must not prevent
 * OpenCode from starting. The provider is registered immediately from config and
 * refreshed once the server is reachable.
 */
export default Plugin.define({
  id: "local-llama",
  async setup(ctx) {
    let cfg: LocalLlamaConfig
    try {
      cfg = readConfig(ctx.options as Record<string, unknown>)
      setDebug(cfg.debug)
      assertPlatform()
      const kit = resolveKit(cfg)
      cfg = { ...cfg, kitPath: kit.kitPath }
      if (kit.created) {
        console.log(`${TAG} scaffolded the llama.cpp kit at ${kit.kitPath}`)
      }
      if (!kitReady(cfg)) {
        throw new Error(`kit is incomplete at ${cfg.kitPath} (expected scripts/serve-up.ps1 and scripts/serve-down.ps1)`)
      }
      // Cheap, synchronous checks: failing here means no provider is registered
      // and OpenCode reports the model as unavailable immediately, instead of
      // retrying against a server that cannot start.
      const problem = preflight(cfg)
      if (problem) throw new Error(problem)
    } catch (error) {
      console.error(TAG, (error as Error).message)
      return
    }

    // Mutable model list: transforms are replayed, so updating this map and
    // triggering another transform refreshes the registry without duplicates.
    // Seed from models.json so a cold start can resolve the model by name, then
    // let discovery fill in context windows and any extra models.
    const models = new Map<string, DiscoveredModel>()
    for (const id of [...Object.keys(cfg.models), ...cfg.fallbackModels]) models.set(id, { id })
    for (const entry of readConfiguredModels(cfg.kitPath!)) {
      if (!models.has(entry.id)) models.set(entry.id, { id: entry.id })
    }

    try {
      // The transform is replayed on every registry rebuild, so it stays valid
      // after discovery adds models. Skip the add while the list is empty.
      await ctx.provider.transform((editor) => {
        if (models.size > 0) editor.add(providerRegistration(cfg, [...models.values()]))
      })
      if (models.size > 0) {
        console.log(`${TAG} provider ${cfg.providerID} registered (${[...models.keys()].join(", ")})`)
      }
    } catch (error) {
      console.error(`${TAG} provider registration failed: ${(error as Error).message}`)
      return
    }

    let owned = false
    let disposed = false
    let supervisor: ReturnType<typeof startSupervisor> | null = null

    /** Stop the server once, whichever path notices first. */
    const teardown = () => {
      if (!owned || !cfg.teardownOnExit) return
      owned = false
      debug("teardown")
      stopServer(cfg)
    }

    const onExit = () => {
      debug("process exit hook")
      supervisor?.stop()
      teardown()
    }
    // CLI shutdown does not always await the cleanup function, so also hook exit.
    process.on("exit", onExit)

    const warm = async () => {
      try {
        if (await isHealthy(cfg)) {
          console.log(`${TAG} adopting the running server at ${cfg.baseURL}`)
        } else {
          owned = true
          debug("starting server")
          const child = spawnServer(cfg)
          // Arm the watchdog immediately: a kill during the first load would
          // otherwise leave the server holding VRAM.
          if (cfg.teardownOnExit) spawnWatchdog(cfg, process.pid)
          await waitForHealth(cfg, cfg.startTimeoutMs, child ? () => child.exitCode === null : undefined)
        }
        if (disposed) return

        const discovered = await discoverModels(cfg)
        const added: string[] = []
        let refreshed = false
        for (const model of discovered) {
          const known = models.get(model.id)
          if (!known) {
            models.set(model.id, model)
            added.push(model.id)
          } else if (model.context && known.context !== model.context) {
            known.context = model.context
            refreshed = true
          }
        }
        if (added.length > 0 || refreshed) {
          // Registering a no-op transform forces the registry to replay ours.
          await ctx.provider.transform(() => {})
          if (added.length > 0) console.log(`${TAG} discovered ${added.length} new model(s): ${added.join(", ")}`)
        }
        const labels = discovered.map((m) => (m.context ? `${m.id} (${m.context} ctx)` : m.id))
        debug(`discovered ${JSON.stringify(discovered)}`)
        console.log(`${TAG} server ready at ${cfg.baseURL} (${labels.join(", ") || "no models"})`)

        if (cfg.supervise && !disposed) {
          supervisor = startSupervisor(cfg, {
            onSpawn: () => {
              owned = true
              // A restart is a new server that also needs teardown coverage.
              if (cfg.teardownOnExit) spawnWatchdog(cfg, process.pid)
            },
          })
        }
      } catch (error) {
        console.error(`${TAG} ${(error as Error).message}`)
      }
    }

    // Fire-and-forget: activation returns immediately.
    void warm()

    return () => {
      debug("cleanup called")
      disposed = true
      process.off("exit", onExit)
      supervisor?.stop()
      teardown()
    }
  },
})
