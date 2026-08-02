/**
 * slim-tools — condensed built-in tool descriptions for local models.
 *
 * OpenCode ships ~16 KB of tool descriptions (~4k tokens) and re-sends them
 * on every request. This plugin swaps them for ~6 KB through the
 * `tool.definition` hook, which is the only place a tool's description can be
 * rewritten before it goes to the model.
 *
 * Host-specific facts in the built-in text (OS, shell, temp directory, default
 * timeout, current year) are lifted out of the original description at runtime
 * so the slim version keeps them accurate.
 *
 * Opt-in: the plugin stays inert unless OPENCODE_SLIM_TOOLS is 1/true/on/yes.
 * Keep the built-in text for individual tools: OPENCODE_SLIM_TOOLS_SKIP=bash,read
 *
 * apply_patch and lsp are left untouched on purpose — their descriptions are
 * format specifications, and paraphrasing those is how you get malformed patches.
 */

/** Pull a dynamic fragment out of the original description. */
const pick = (text, re, fallback = "") => {
  const m = typeof text === "string" ? text.match(re) : null
  return m ? (m[1] ?? m[0]) : fallback
}

const descriptions = {
  bash: (original) => {
    const beAware = pick(original, /^Be aware: .*$/m, "Be aware: OS: linux, Shell: bash")
    const tmp = pick(original, /Use `([^`]+)` for temporary work/, "/tmp/opencode")
    const timeout = pick(original, /time out after (\d+)ms/, "120000")
    return `Run a bash command in a persistent shell session.

${beAware}

- Run somewhere else with the \`workdir\` parameter. Do NOT use \`cd <dir> && <command>\`.
- Quote paths containing spaces: \`python "/path/with spaces/script.py"\`.
- \`timeout\` is optional, in milliseconds; commands time out after ${timeout}ms by default.
- Use \`${tmp}\` for temporary work outside the workspace. It already exists and is pre-approved.
- Output over 2000 lines or 50 KB is truncated and written to a file — read it back with read/grep instead of piping through \`head\`/\`tail\`.
- Terminal operations only (git, npm, docker, tests). For files use the dedicated tools: glob (not find/ls), grep (not grep/rg), read (not cat/head/tail), edit (not sed/awk), write (not echo >). Reply in text rather than \`echo\`.
- Independent commands: several bash calls in one message, so they run in parallel. Dependent ones: chain with \`&&\` in a single call. Never separate commands with newlines.

Git: commit, amend, push, or open a PR only when the user asks. Check \`git status\` and \`git diff\` first, stage only what you intended, never commit secrets, and match the repo's commit style. Do not amend a rejected commit, force-push, skip hooks, or change git config unless asked. Use \`gh\` for GitHub work and return the PR URL.`
  },

  edit: `Exact string replacement in a file.

- Read the file first — an edit without a prior read errors.
- \`oldString\` must match the file exactly, including indentation, but must never include the \`N: \` line-number prefix that read adds.
- The edit fails if \`oldString\` is absent, or if it matches more than once. Add surrounding lines to make it unique, or set \`replaceAll\` to change every occurrence (use that for renames).
- Prefer editing existing files over creating new ones. Only add emojis if asked.`,

  glob: `Fast file-name search by glob pattern ("**/*.js", "src/**/*.ts"), any codebase size. Returns matching paths.

Batch several globs into one message when more than one pattern is worth trying. For open-ended searches that need multiple rounds of globbing and grepping, use the task tool instead.`,

  grep: `Fast content search by regular expression ("log.*Error", "function\\s+\\w+"), any codebase size. Returns file paths and matching lines with line numbers.

Narrow the search with \`include\` ("*.js", "*.{ts,tsx}"). To count matches, run \`rg\` through bash. For open-ended searches that need multiple rounds of globbing and grepping, use the task tool instead.`,

  read: `Read a file or directory; errors if the path does not exist.

- \`filePath\` must be absolute. Use glob if you are unsure of it.
- Returns up to 2000 lines (\`limit\`) starting at \`offset\` (1-indexed), each line prefixed \`<line>: \`. Directory entries come one per line, subdirectories with a trailing \`/\`. Lines over 2000 characters are truncated.
- Read a large window rather than repeated 30-line slices, and read files in parallel when you need several.
- Use grep to locate content in large files.
- Images and PDFs are returned as attachments.`,

  write: `Write a file, overwriting whatever is at that path.

- For an existing file you MUST read it first; the write fails otherwise.
- Prefer editing existing files. Never create documentation or README files unless the user asked for them. Only add emojis if asked.`,

  skill: `Load a skill listed in the system prompt, injecting its instructions and resources into the conversation. Its output may reference scripts and files next to the skill. \`name\` must match one of available_skills.`,

  todowrite: `Maintain the task list for this session.

Use it when the work has 3+ distinct steps, when the user gives several tasks or asks for a list, and when new instructions arrive. Skip it for a single straightforward task or a purely informational request. When in doubt, use it.

States: \`pending\`, \`in_progress\` (exactly one at a time), \`completed\`, \`cancelled\`.

- Update status as you go, not in batches.
- Mark \`completed\` only once the work — including any verification it required — is actually done, never on intent.
- If blocked or only partly done, leave it \`in_progress\` and add a follow-up todo naming the blocker.
- Keep items specific and actionable, and preserve user-provided commands verbatim.`,

  task: `Launch a subagent to handle a complex, multi-step task autonomously. \`subagent_type\` selects the agent.

Do not use it to read a known path (read/glob), to find a specific definition (grep), or to work within 2-3 known files (read). If no agent fits, use the tools directly.

- Launch independent agents in parallel from a single message, and do not redo work you delegated.
- Each call starts from a fresh context unless you pass \`task_id\` to resume that subagent. Write a self-contained prompt stating what to do, whether you want research or code changes, how to verify, and exactly what to report back.
- The agent answers once. The user does not see that answer — summarize what matters yourself.`,

  webfetch: `Fetch a URL and return its content as markdown (default), text, or html.

The URL must be fully formed; HTTP is upgraded to HTTPS. Read-only, and very large pages may be summarized. Prefer a more targeted or less restricted fetch tool if one is available.`,

  websearch: (original) => {
    const year = pick(original, /The current year is (\d{4})/, "")
    return `Search the web through the session's search provider for information past your knowledge cutoff, and return content from the most relevant pages. Runs within a single call.

Optional where supported: result count, context length, domain filters, live crawling ('fallback' or 'preferred') and search type ('auto', 'fast', 'deep').${
      year
        ? `\n\nThe current year is ${year}. You MUST search with it for anything recent — for "latest AI news", search "AI news ${year}".`
        : ""
    }`
  },

  question: `Ask the user a question while working — to gather requirements, clarify an ambiguous instruction, or choose a direction.

Answers come back as an array of labels; set \`multiple: true\` to allow more than one. With \`custom\` enabled (the default) a "type your own answer" option is added automatically, so do not write an "Other" option yourself. Put any option you recommend first and end its label with "(Recommended)".`,
}

/** Parameter descriptions worth shortening; keyed by tool, then property. */
const parameters = {
  glob: {
    path: "Directory to search in. Omit for the current working directory — do not pass 'undefined' or 'null'.",
  },
  read: {
    offset: "Line number to start reading from (1-indexed)",
    limit: "Maximum lines to read (default 2000)",
  },
}

const ENABLED = new Set(["1", "true", "on", "yes"])

export const SlimTools = async () => {
  if (!ENABLED.has((process.env["OPENCODE_SLIM_TOOLS"] ?? "").toLowerCase())) return {}
  const skip = new Set(
    (process.env["OPENCODE_SLIM_TOOLS_SKIP"] ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  )

  return {
    "tool.definition": async (input, output) => {
      const id = input.toolID
      if (skip.has(id)) return

      const slim = descriptions[id]
      if (slim) output.description = typeof slim === "function" ? slim(output.description) : slim

      // Parameter descriptions live in the JSON schema. Older opencode builds
      // do not expose it on the hook output; skip rather than guess.
      const overrides = parameters[id]
      if (overrides && output.jsonSchema?.properties) {
        const schema = structuredClone(output.jsonSchema)
        for (const [name, description] of Object.entries(overrides)) {
          if (schema.properties[name]) schema.properties[name].description = description
        }
        output.jsonSchema = schema
      }
    },
  }
}
