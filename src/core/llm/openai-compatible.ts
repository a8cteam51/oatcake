import { OPENAI_KEY_ENV, type Effort } from "../config.ts";
import type { Llm } from "./index.ts";

/** Any OpenAI-style chat completions endpoint: OpenAI, OpenRouter, or a local Ollama / LM Studio. */
export function openaiCompatible(config: { baseUrl: string; model: string; effort: Effort }): Llm {
  return {
    label: `${config.model} via ${config.baseUrl}`,
    async complete(system, prompt) {
      if (!config.baseUrl || !config.model) throw new Error("Set the endpoint and model in Settings first.");
      const key = process.env[OPENAI_KEY_ENV];
      const send = (withEffort: boolean) =>
        fetch(`${config.baseUrl.replace(/\/$/, "")}/chat/completions`, {
          method: "POST",
          headers: { "content-type": "application/json", ...(key ? { authorization: `Bearer ${key}` } : {}) },
          body: JSON.stringify({
            model: config.model,
            ...(withEffort ? { reasoning_effort: config.effort } : {}),
            messages: [
              { role: "system", content: system },
              { role: "user", content: prompt },
            ],
          }),
        });
      // Servers and models without reasoning reject the effort setting; ask again without it.
      let res = await send(true);
      if (res.status === 400) res = await send(false);
      if (!res.ok) throw new Error(`${config.baseUrl} returned ${res.status}: ${await res.text()}`);
      const body = (await res.json()) as { choices: { message: { content: string } }[] };
      return body.choices[0]?.message.content ?? "";
    },
  };
}
