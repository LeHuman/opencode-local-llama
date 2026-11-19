import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import type { LocalLlamaConfig } from "./config"

/** Framework shipped inside the plugin package (read-only template). */
const FRAMEWORK_DIR = fileURLToPath(new URL("../kit", import.meta.url))

export interface ResolvedKit {
  kitPath: string
  /** True when this run created the scaffold. */
  created: boolean
}

/**
 * Copy the framework into the kit, overwriting files that came from the package.
 * User-owned files live outside kit/ (config.json at the kit root, models and
 * build directories), so they are never touched by an upgrade.
 */
function copyFramework(src: string, dest: string): number {
  let copied = 0
  mkdirSync(dest, { recursive: true })
  for (const entry of readdirSync(src)) {
    const from = path.join(src, entry)
    const to = path.join(dest, entry)
    if (statSync(from).isDirectory()) {
      copied += copyFramework(from, to)
      continue
    }
    copyFileSync(from, to)
    copied++
  }
  return copied
}

/**
 * Machine-level config.json: paths, endpoint, router behaviour, and the few
 * knobs that are common across models. Per-model data lives in
 * <modelsDir>/models.json and is never written by the plugin.
 */
function writeKitConfig(kitPath: string, cfg: LocalLlamaConfig): void {
  const file = path.join(kitPath, "config.json")
  let current: Record<string, unknown> = {}
  if (existsSync(file)) {
    try {
      current = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>
    } catch {
      return // leave a hand-edited, unparseable config alone
    }
  }

  const trim = (p: string) => (p.length > 3 ? p.replace(/[\\/]+$/, "") : p)
  if (cfg.modelsPath) current.modelsDir = trim(cfg.modelsPath)
  else if (typeof current.modelsDir !== "string") current.modelsDir = "models"
  if (cfg.binPath) current.toolsDir = trim(cfg.binPath)
  current.host = cfg.host
  current.port = cfg.port
  current.sleepIdleSeconds ??= 900
  current.routerMode ??= true
  current.modelsMax ??= 1
  current.minBuild ??= 0
  current.defaults ??= { temperature: 1.0, topP: 0.95 }

  writeFileSync(file, `${JSON.stringify(current, null, 2)}\n`, "utf8")
}

/**
 * Ids declared by the kit's models.json, read synchronously at activation so a
 * cold start can resolve `-m local-llama/<id>` before the server is discovered.
 * Discovery later reconciles context windows and adds anything missing.
 */
export function readConfiguredModels(kitPath: string): Array<{ id: string }> {
  try {
    const kitConfig = JSON.parse(readFileSync(path.join(kitPath, "config.json"), "utf8")) as {
      modelsDir?: string
    }
    const modelsDir = kitConfig.modelsDir
      ? path.isAbsolute(kitConfig.modelsDir)
        ? kitConfig.modelsDir
        : path.join(kitPath, kitConfig.modelsDir)
      : path.join(kitPath, "models")
    const modelsConfig = JSON.parse(readFileSync(path.join(modelsDir, "models.json"), "utf8")) as {
      models?: Record<string, { alias?: string } | undefined>
    }
    // Only advertise entries whose weights exist: a leftover entry for a
    // deleted GGUF would register an id that can never load.
    const stems = new Set(
      existsSync(modelsDir)
        ? readdirSync(modelsDir)
            .filter((file) => file.toLowerCase().endsWith(".gguf"))
            .map((file) => path.parse(file).name.toLowerCase())
        : [],
    )
    const ids: Array<{ id: string }> = []
    for (const [stem, entry] of Object.entries(modelsConfig.models ?? {})) {
      if (!stems.has(stem.toLowerCase())) continue
      const id = entry?.alias ?? stem
      if (id) ids.push({ id })
    }
    return ids
  } catch {
    return []
  }
}

/**
 * Resolve the kit folder. An explicit `kitPath` is used as-is; otherwise the
 * bundled framework is copied into a writable data directory (never the package
 * cache, which is versioned and disposable). Existing files are never
 * overwritten, so upgrades add new scripts without clobbering local edits.
 */
export function resolveKit(cfg: LocalLlamaConfig): ResolvedKit {
  const explicit = cfg.kitPath
  if (explicit) {
    if (!existsSync(path.join(explicit, "scripts", "serve-up.ps1"))) {
      throw new Error(`kitPath has no scripts/serve-up.ps1: ${explicit}`)
    }
    writeKitConfig(explicit, cfg)
    return { kitPath: explicit, created: false }
  }

  if (!existsSync(FRAMEWORK_DIR)) {
    throw new Error(`bundled framework missing from the package (${FRAMEWORK_DIR}); set options.kitPath`)
  }

  const dataDir = cfg.dataDir ?? path.join(process.env.LOCALAPPDATA ?? process.cwd(), "opencode-local-llama")
  const kitPath = path.join(dataDir, "kit")
  const before = existsSync(path.join(kitPath, "scripts", "serve-up.ps1"))
  const copied = copyFramework(FRAMEWORK_DIR, kitPath)
  writeKitConfig(kitPath, cfg)

  return { kitPath, created: !before || copied > 0 }
}
