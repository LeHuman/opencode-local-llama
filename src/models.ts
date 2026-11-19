import { Model, Provider } from "@opencode/plugin"
import type { LocalLlamaConfig } from "./config"
import type { DiscoveredModel } from "./kit"

/**
 * Human-readable label from a model id: "My-Model" -> "My Model".
 * Sizes are not inferred from GGUF metadata on purpose: llama.cpp reports all
 * tensors, so models with large embedding tables overstate their parameter
 * count, and a wrong number is worse than none. Set `models.<id>.name` to pin.
 */
function prettyName(id: string): string {
  const cleaned = id
    .replace(/[._]+/g, " ")
    .replace(/-+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
  return cleaned.length > 0 ? cleaned : id
}

/**
 * Build the provider registration added through ctx.provider.transform.
 * Model ids come from llama-server's /v1/models (router mode lists every GGUF),
 * and the context window is taken from the server's own launch args, so nothing
 * has to be kept in sync by hand. `models` in the plugin options only overrides
 * the label or limits where the defaults are wrong.
 */
export function providerRegistration(cfg: LocalLlamaConfig, discovered: DiscoveredModel[]) {
  const providerID = Provider.ID.make(cfg.providerID)

  const models = discovered.map(({ id, context }) => {
    const base = Model.Info.default(providerID, Model.ID.make(id))
    const meta = cfg.models[id] ?? {}
    return {
      ...base,
      name: meta.name ?? prettyName(id),
      limit: {
        ...base.limit,
        context: meta.context ?? context ?? cfg.defaultContext,
        output: meta.output ?? cfg.defaultOutput,
      },
      // Most local models need tools enabled explicitly for agent use.
      capabilities: { ...base.capabilities, tools: true },
    }
  })

  return {
    info: {
      ...Provider.Info.empty(providerID),
      name: cfg.providerName,
      activation: "enabled" as const,
      package: "@opencode/ai/providers/openai-compatible",
      settings: { baseURL: cfg.baseURL },
    },
    models,
  }
}
