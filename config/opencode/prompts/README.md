# Slim System Prompts

Drop-in replacements for OpenCode's built-in system prompts, sized for local
models running in the container (Qwen, Devstral, GLM, and friends).

| File | Replaces | Size | Built-in size |
|------|----------|------|---------------|
| `build-slim.md` | `default.txt` (build/plan agent) | ~4.8 KB | ~8.5 KB |
| `title-slim.md` | `title.txt` (session title agent) | ~0.7 KB | ~2.1 KB |

## Why

OpenCode compiles its prompts **into the binary** — there is no `.txt` on disk
in the container to edit. The prompt is selected by substring match on the
model ID, so anything that isn't `gpt*`, `gemini-*`, `claude*`, `trinity*` or
`kimi*` — every local model — falls through to `default.txt`.

That prompt plus the environment block, `AGENTS.md`, the MCP instructions and
the skills list is roughly 2–3k tokens of preamble on **every** request. On a
70B+ frontier model that's noise. On a 30B local model it is a meaningful slice
of the context window, and the parts about opencode's issue tracker and the
`/help` command are never going to be useful.

The slim versions keep what actually steers behaviour — concision, search
before edit, check the library exists, verify with tests, don't commit unless
asked, `file_path:line_number` — and drop the product boilerplate and the long
verbosity examples.

`build-slim.md` then **adds** two sections the built-in prompt does not have:
`# Naming` (self-explanatory, fully spelled-out identifiers) and `# Above all`
(think first, keep it simple, keep changes surgical). Those are house rules,
not a slimming measure — together they are roughly half the file, and they are
why it is 4.8 KB rather than the 2.4 KB it started at. Still well under the
8.5 KB built-in, but if you want the prompt as small as it goes, delete them;
if you want them to apply to every agent instead of just build/plan, move them
into `AGENTS.md`.

## Enabling them

The prompts are copied to `~/.config/opencode/prompts/` by `setup.sh`, and that
directory is mounted read-only into the container at
`/home/coder/.config/opencode`. Nothing needs rebuilding — edit on the host,
restart OpenCode.

Add to `~/.config/opencode/opencode.json`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "agent": {
    "build": { "prompt": "{file:./prompts/build-slim.md}" },
    "plan":  { "prompt": "{file:./prompts/build-slim.md}" },
    "title": { "prompt": "{file:./prompts/title-slim.md}" }
  }
}
```

`{file:...}` resolves relative to the config file's own directory; `~/` and
absolute paths work too.

Setting `prompt` **replaces** the built-in prompt — it is not appended. Use
`instructions` or `AGENTS.md` when you want to add to the default instead.

An equivalent way to override an agent, without touching `opencode.json`: drop
a markdown file in `~/.config/opencode/agent/<name>.md`. The body of the file
becomes that agent's prompt, and it works for the hidden built-in agents
(`title`, `summary`, `compaction`, `explore`) too.

## Trimming further

Two parts of the system prompt are not agent-prompt fields:

**Skills list** — skipped entirely when the agent can't use skills:

```jsonc
{ "agent": { "build": { "permission": { "skill": "deny" } } } }
```

**Environment block** (model ID, working directory, git status, date) — only
reachable from a plugin. Put this in `~/.config/opencode/plugin/trim-system.js`:

```js
export const TrimSystem = async () => ({
  "experimental.chat.system.transform": async (input, output) => {
    output.system = output.system.filter((s) => !s.startsWith("You are powered by the model named"))
  },
})
```

The same hook can strip arbitrary sections out of the stock prompt if you would
rather trim than replace.

**Tool descriptions** — another ~16 KB sent with every request, and bigger than
the system prompt itself. See [`../plugin/README.md`](../plugin/README.md) for
`slim-tools.js`, which rewrites them through the `tool.definition` hook.

## Caveats

- Replacement is total. If you cut a rule, the model no longer has it — smaller
  models drift more than frontier ones, so trim in steps and watch the results.
- Plan mode injects `plan.txt` separately as a reminder, not through the agent
  prompt, so overriding `agent.plan.prompt` won't remove it.
- These track OpenCode's prompts as of v1.18.x. Upstream changes to
  `default.txt` won't flow into them.

## Seeing what is actually sent

The prompts are embedded as plain strings in the binary. `npm`'s postinstall
copies the real compiled binary to `bin/opencode.exe`, so `readlink -f` on the
`opencode` in `PATH` lands on it directly. Inside the container:

```bash
strings -n 4 "$(readlink -f "$(which opencode)")" \
  | grep -m1 -A 60 -F 'You are opencode, an interactive CLI tool'
```

Swap the grep pattern for `You are a title generator` to get the title prompt,
or `You are OpenCode, the best coding agent` for the Anthropic variant. To see
which prompt your model actually resolves to, check the substring rules in
`packages/opencode/src/session/system.ts` upstream.

For the fully assembled request — base prompt plus environment block plus
`AGENTS.md` plus skills — use the LLM interceptor
(`setting.llm_interceptor_support=true`, see the main README) and read it off
the wire.
