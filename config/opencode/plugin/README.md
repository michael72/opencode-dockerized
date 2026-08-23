# Plugins

Dropped into `~/.config/opencode/plugin/` by `setup.sh`. OpenCode loads every
`*.js` / `*.ts` in that directory automatically, so anything shipped here has to
be inert until you switch it on.

| File | Does | Enable with |
|------|------|-------------|
| `slim-tools.js` | Condensed built-in tool descriptions | `OPENCODE_SLIM_TOOLS=1` |

## slim-tools

The system prompt is not the only fixed cost per request. OpenCode's built-in
tool descriptions are ~16 KB (~4k tokens) of JSON that is re-sent, in full, with
every single message. `bash` alone is 4.6 KB — more than the entire slim build
prompt in `../prompts/build-slim.md`.

This plugin replaces them through the `tool.definition` hook, which is the only
place a tool's description can be rewritten before it reaches the model.

| Tool | Slim | Built-in |
|------|------|----------|
| `bash` | 1.3 KB | 4.6 KB |
| `task` | 0.7 KB | 2.3 KB |
| `todowrite` | 0.7 KB | 2.0 KB |
| `edit` | 0.5 KB | 1.4 KB |
| `read` | 0.5 KB | 1.2 KB |
| `websearch` | 0.45 KB | 1.0 KB |
| `write` | 0.43 KB | 0.6 KB |
| `question` | 0.4 KB | 0.7 KB |
| `grep` | 0.35 KB | 0.7 KB |
| `glob` | 0.3 KB | 0.5 KB |
| `webfetch` | 0.26 KB | 0.75 KB |
| `skill` | 0.2 KB | 0.4 KB |
| **total** | **6.2 KB** | **16.1 KB** |

Roughly 2.5k tokens back per request with the full tool set; ~1.5k with the
default seven (`bash`, `edit`, `glob`, `grep`, `read`, `skill`, `write`), where
it is 9.4 KB → 3.6 KB.

`apply_patch` and `lsp` are deliberately left alone — their descriptions are
format specifications, and paraphrasing a patch format is how you get patches
that don't apply.

### What is kept

Every rule that changes what the model *does* survives: read-before-edit, the
`oldString` uniqueness rules, `workdir` instead of `cd`, use the dedicated tools
instead of `cat`/`sed`/`find`, batch independent calls, don't commit unless
asked, exactly one `in_progress` todo. What goes is the restatement — the
"Usage notes:" preamble, the `<good-example>` / `<bad-example>` pairs, the
worked todo examples, and the sentences that say the same thing a second time.

Host-specific values are read back out of the original description at runtime
rather than hardcoded, so OS, shell, the temp directory, the default timeout,
and the current year stay correct.

`write` gains one line the built-in text does not have: a warning that `content`
travels in a single tool call, so a very long file can exceed the model's output
limit and arrive truncated — which surfaces as
`Invalid input for tool write: JSON parsing failed ... Unterminated string`. The
fix is to raise `limit.output` for the model in `opencode.json` *and* the
inference server's own cap (`num_predict`, `--n-predict`, "max tokens"); the
description just nudges the model to write long files in sections meanwhile.

Writing files through `bash` (`cat > file`) is not the workaround, which is why
that rule survives condensing: `write` and `edit` run under the `edit`
permission, trigger the formatter, and return LSP diagnostics in the tool
result, while a heredoc does none of that — and its body travels in the same
single tool call, so it truncates at exactly the same point.

### Enabling

The plugin is inert unless `OPENCODE_SLIM_TOOLS` is `1`, `true`, `on`, or `yes`.

In the container, add it as a custom environment variable during
`./setup.sh` (or to `~/.config/opencode-dockerized/config`):

```
env.custom1=OPENCODE_SLIM_TOOLS
```

then export it on the host before running, so the wrapper forwards the value:

```bash
export OPENCODE_SLIM_TOOLS=1
opencode-dockerized
```

Running OpenCode directly on the host needs only the export. Either way it
takes effect on the next start — the plugin directory is mounted, nothing gets
rebuilt.

To keep the built-in text for particular tools:

```bash
export OPENCODE_SLIM_TOOLS_SKIP=bash,todowrite
```

### Checking that it worked

The descriptions go out on the wire, so read them there with the LLM
interceptor (`setting.llm_interceptor_support=true`, see the main README) and
look at `tools[].function.description` in the captured request.

For the built-in text to compare against, the strings are compiled into the
binary:

```bash
strings -n 4 "$(readlink -f "$(which opencode)")" \
  | grep -m1 -A 40 -F 'Performs exact string replacements in files'
```

### Caveats

- `tool.definition` arrived in OpenCode 1.18. On anything older the hook never
  fires and the plugin quietly does nothing.
- Replacement is total, same as with the slim prompts. A rule you cut is a rule
  the model no longer has, and smaller models drift more — turn it on, watch a
  few sessions, and use `OPENCODE_SLIM_TOOLS_SKIP` for whichever tool misbehaves.
- MCP and plugin-provided tools are untouched; only the ids listed above match.
- The parameter JSON schemas are left as-is apart from two verbose `glob` and
  `read` field descriptions. Older builds don't expose `jsonSchema` on the hook,
  in which case that part is skipped.
- These track OpenCode's descriptions as of v1.18.x. Upstream edits to the
  built-in text won't flow into them.
