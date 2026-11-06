import Anthropic from "@anthropic-ai/sdk";
import type { Llm } from "./index.ts";

/**
 * Claude through the Anthropic API. Credentials come from ANTHROPIC_API_KEY (set from the key
 * saved in Settings, or your own environment). Server-side refusal fallbacks are on, so a declined
 * request is retried on a fallback model inside the same call.
 */
export function anthropic(config: { model: string; effort: "low" | "medium" | "high" }): Llm {
  const client = new Anthropic();
  return {
    label: `${config.model} via Anthropic API`,
    async complete(system, prompt) {
      const message = await client.beta.messages
        .stream({
          model: config.model,
          max_tokens: 64000,
          betas: ["server-side-fallback-2026-07-01"],
          fallbacks: "default",
          output_config: { effort: config.effort },
          system,
          messages: [{ role: "user", content: prompt }],
        })
        .finalMessage();
      if (message.stop_reason === "refusal") {
        throw new Error(`Claude declined: ${message.stop_details?.explanation ?? "no explanation"}`);
      }
      return message.content
        .flatMap((block) => (block.type === "text" ? [block.text] : []))
        .join("")
        .trim();
    },
  };
}
