# Slim System Prompts

| File | Replaces | Size | Built-in size |
|------|----------|------|---------------|
| `title-slim.md` | session title agent prompt | ~0.7 KB | ~2.1 KB |

Copied to `~/.config/opencode/prompts/` by `setup.sh`. **Not active by default.**

## Why only the title prompt

OpenCode V1 shipped an 8.5 KB build prompt, and a slimmer replacement paid off. V2 cut
its own prompts and tool descriptions down, so that is no longer true. Measured on
`@opencode/cli` 2.0.22, with a model that is not `gpt*`/`gemini-*`/`claude*`:

| Part | Built-in | Slim replacement |
|------|----------|------------------|
| Build/plan agent prompt | 1.5 KB | 3.4 KB (larger, so no longer shipped) |
| Title agent prompt | 2.1 KB | 0.7 KB |

The rest of the system message (Code Mode, skills list, environment) and the tool schemas
are not part of an agent prompt and cannot be replaced this way.

## Enabling the title prompt

Add to `~/.config/opencode/opencode.json`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "agent": {
    "title": { "prompt": "{file:./prompts/title-slim.md}" }
  }
}
```

`{file:...}` resolves relative to the config file. `~/.config/opencode/` is mounted into
the container, so it takes effect on the next start. Setting `prompt` **replaces** the
built-in prompt. To add instructions instead, use `AGENTS.md` or `instructions`.

## Checking what is actually sent

V2 has no command that prints the final request. Read it on the wire instead:

- the LLM interceptor (`setting.llm_interceptor_support=true`, see the main README) and
  look at `messages[0]` (system) and `tools[]`, or
- send one trivial message in a fresh session and read the provider's reported input
  tokens, or
- point OpenCode at a small local OpenAI-compatible server that logs request bodies.

Characters ÷ 4 is a fair token estimate. Note that `tools[]` is mostly parameter
schemas; descriptions are well under half of it.
