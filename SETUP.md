# Setup Guide (`setup.sh`)

`./setup.sh` is the first-time initialisation script. It is safe to re-run at any time. This
document walks through every question it can ask, what each answer changes on your machine, and —
where it applies — what you are trading away in terms of security.

- [Before you start: the security baseline](#before-you-start-the-security-baseline)
- [What `setup.sh` does, in order](#what-setupsh-does-in-order)
- [Step 1 — Directories and files (no choice)](#step-1--directories-and-files-no-choice)
- [Step 2 — Existing config: append / overwrite / skip](#step-2--existing-config-append--overwrite--skip)
- [Step 3 — Settings](#step-3--settings)
- [Step 4 — Custom mounts](#step-4--custom-mounts)
- [Step 5 — Environment variables](#step-5--environment-variables)
- [Step 6 — Shell completions](#step-6--shell-completions)
- [Step 7 — Shell aliases](#step-7--shell-aliases)
- [Step 8 — Global install](#step-8--global-install)
- [Summary: risk by choice](#summary-risk-by-choice)
- [What gets downloaded, and where it lands on `PATH`](#what-gets-downloaded-and-where-it-lands-on-path)
- [A conservative set of answers](#a-conservative-set-of-answers)
- [Undoing what `setup.sh` did](#undoing-what-setupsh-did)

---

## Before you start: the security baseline

`setup.sh` only controls the *optional* parts. Several things that matter more for security are
**not** configurable through it and apply no matter what you answer. Read this section first, because
it changes how the risks below should be weighed.

| Fact (no setting turns it off) | Consequence |
|---|---|
| The container's `coder` user has **passwordless `sudo`** (`Dockerfile`: `coder ALL=(ALL) NOPASSWD:ALL`). | Anything running as `coder` — OpenCode, a tool it launches, a script from the repo it is working on — can become **root inside the container**. |
| `run` and `exec` mount the **host Docker socket** (`/var/run/docker.sock`) read-write. | Access to the Docker socket is, in practice, **root on the host**: a process can start a new container that bind-mounts `/` (or runs `--privileged`). The container itself is not privileged, but this is an escalation path to the host that bypasses the sandbox. It is the price of Testcontainers / `docker build` support. |
| The container uses **`--network host`**. | Unrestricted outbound network (data exfiltration is trivial), and everything listening on the host's loopback — databases, dev servers, an exposed Docker TCP port, `lli`'s proxy — is reachable. Docker's default capability set (which includes `NET_RAW`) also applies to root-in-container. |
| The **project directory is mounted read-write**. | The agent can plant files that run on the *host* later, when you do something ordinary: `.git/hooks/*`, `.envrc`, `Makefile`, `package.json` scripts, `.vscode/tasks.json`, CI files, build plugins. Review diffs before you commit, build, or open the project in an IDE outside the container. |
| `~/.local/share/opencode` (contains `auth.json`, your provider credentials) is mounted **read-write**; `~/.mcp-auth` and `~/.config/opencode` are mounted read-only — which still means **readable**. | The agent, and anything it runs, can read your LLM provider and MCP credentials and send them anywhere. Use provider keys with spending limits / narrow scopes. |
| `~/.npm`, `~/.m2`, `~/.gradle` and `~/.bun/install/cache` are shared with the host **read-write**. | Cache poisoning: a tampered package or jar left in a shared cache can be picked up by your host builds. (This is exactly why the optional sbt/uv caches below are *private* and start empty.) |
| The entrypoint runs **as root** until it drops privileges (`setpriv`). It installs the optional CA, copies skills and starts `pumlsrv-server` before the drop. | `pumlsrv-server` — a binary fetched at image-build time — therefore runs as root inside the container on every launch. |

**Bottom line:** the container is a very effective guard against *accidents* (`rm -rf .` only reaches
the project, a bad `npm install` can't touch your home directory). It is **not** a hard boundary
against a malicious or prompt-injected agent that deliberately tries to escape — treat the Docker
socket and `sudo` accordingly, and don't run the tool against untrusted repositories on a machine that
holds secrets you can't afford to lose.

You can always inspect exactly what a launch will mount and pass without starting anything:

```bash
DRY_RUN=true ./opencode-dockerized.sh run /path/to/project
```

---

## What `setup.sh` does, in order

| # | Step | Needs input? | Touches |
|---|---|---|---|
| 1 | Create OpenCode directories and a default `opencode.json` | no | `~/.config/opencode`, `~/.local/{share,state}/opencode`, `~/.cache/…`, `~/.mcp-auth` |
| 2 | Choose what to do with an existing config | only if a config exists | `~/.config/opencode-dockerized/config` |
| 3 | Settings (SSH agent, LLM interceptor, Graphify, Matt Pocock skills, sbt cache, uv cache) | yes | same config file |
| 4 | Custom mounts | yes | same config file |
| 5 | Environment variables | yes | same config file (names only) |
| 6 | Shell completions | yes | `~/.bashrc` and/or `~/.zshrc` |
| 7 | Shell aliases | yes | `~/.bashrc` and/or `~/.zshrc` |
| 8 | Global install (symlink on `PATH`) | yes | `~/.local/bin`, `~/.bashrc`, `~/.zshrc` |

`setup.sh` itself needs **no root/sudo**, downloads **nothing**, and never talks to Docker. The
image is built afterwards with `opencode-dockerized build` (see
[What gets downloaded](#what-gets-downloaded-and-where-it-lands-on-path)).

---

## Step 1 — Directories and files (no choice)

Creates, if missing: `~/.config/opencode/{agent,plugin,command}`, `~/.local/share/opencode`,
`~/.local/state/opencode`, `~/.cache/opencode`, `~/.cache/oh-my-opencode`, `~/.mcp-auth`, and
`~/.config/opencode/opencode.json` (`{}`) unless an `opencode.json`/`opencode.jsonc` already exists.

It also removes a leftover `~/.config/opencode/plugin/slim-tools.js` from older versions — but only
if the file contains the signature `export const SlimTools` — and the plugin `README.md` next to it
if that mentions `slim-tools`. Files you wrote yourself are left alone, but if you keep your own
notes in `plugin/README.md` that mention "slim-tools", back them up first.

**Risk:** none from creation. Note that the directories above are exactly the ones the container later
sees (see the baseline table), so what you put in them is visible to the agent.

---

## Step 2 — Existing config: append / overwrite / skip

Shown only when `~/.config/opencode-dockerized/config` already exists.

| Choice | Effect |
|---|---|
| **Append** | Loads the current values as defaults, asks all questions again, rewrites the file. |
| **Overwrite** | Ignores the current file and starts from built-in defaults. Previous mounts and env entries are lost. |
| **Skip** | Keeps the file untouched and skips steps 3–5. |

Both *append* and *overwrite* **regenerate the file**: hand-written comments are dropped and mount/env
entries are renumbered (`mount.custom1`, …). Keep a copy if you maintain the file by hand.

**Risk:** low. Be aware that *overwrite* silently discards earlier hardening (e.g. you re-enable a
default you had switched off) — re-read the printed summary at the end.

If the config does not exist yet, you are asked whether to configure anything. Answering **N** writes
a default config — it does **not** mean "everything off": [Graphify](#graphify--default-on) is on by
default.

---

## Step 3 — Settings

All settings are stored as `setting.<name>=<value>` in `~/.config/opencode-dockerized/config`.
Booleans are only enabled by an exact `true`, except `graphify_support`, which is only disabled by
an exact `false`.

### SSH agent forwarding — default off

`setting.ssh_agent_support`

Mounts the socket named by `$SSH_AUTH_SOCK` into the container at the same path and passes the
variable through, so `git` over SSH works without copying keys.

- **What it protects:** your private keys never enter the container (they cannot be read out of the
  agent).
- **Risk — medium:** while the container runs, anything inside it (including the agent, and — via
  `sudo` — root, which bypasses socket permissions) can **use every key loaded in your agent**: push
  to any repository those keys can reach, or log in to any server that trusts them. It does not need
  to steal the key, and there is no prompt.
- **Mitigations:** run a dedicated agent that holds only a narrowly scoped key (e.g. a per-repo
  deploy key); load keys with `ssh-add -c` (confirm every use) or `ssh-add -t <seconds>` (expire);
  leave this off and use HTTPS with a scoped token for sessions that don't need pushing.
- Do **not** mount `~/.ssh` instead — that hands over the private keys themselves (see
  [custom mounts](#step-4--custom-mounts)).

### LLM traffic interception — default off

`setting.llm_interceptor_support`, `setting.llm_interceptor_port` (default `9090`),
`setting.llm_interceptor_capture_local`

For debugging/auditing prompts and responses with [`lli`](https://pypi.org/project/llm-interceptor/)
(mitmproxy based), which you run on the **host** (`lli watch`). When enabled:

- `~/.mitmproxy` is mounted **read-only** into the container;
- the entrypoint (as root) installs `mitmproxy-ca-cert.pem` into the container's system trust store
  and sets `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`;
- `HTTP(S)_PROXY` is set to `127.0.0.1:<port>`.

**Risks — medium to high:**

- **Man-in-the-middle by design.** The proxy decrypts *all* HTTPS from the container — not just
  LLM calls — including `Authorization` headers and API keys. What `lli` writes to disk depends on its
  filter, but mitmproxy sees everything. Traces on the host may contain secrets and your source
  code; protect and clean them.
- **The whole `~/.mitmproxy` directory is mounted**, not just the certificate. In mitmproxy's default
  layout that directory also holds the **CA private key** (`mitmproxy-ca.pem`, plus `.p12` variants).
  Verify with `ls ~/.mitmproxy`. Whoever has that key can forge certificates for any site to any
  client that trusts the CA. If you have also installed this CA into your **host** or browser trust
  store (common when using mitmproxy), the exposure extends beyond the container. Don't trust this CA
  on the host, and consider a dedicated CA used only for this purpose.
- **The proxy listens on host loopback**, so any local process or user can use it.
- **Fail-closed:** if `lli watch` is not running, the container's HTTPS calls fail.
- `capture_local=true` stops exempting loopback (`localhost,127.0.0.1,::1`) from the proxy so that
  local models (llama-server, ollama) get captured. As a side effect the in-container `pumlsrv`
  also goes through the proxy. The private OpenCode server is moved to `127.0.0.2`, which stays
  exempt.
- The port prompt only accepts 1–65535; anything else keeps the previous value.

Enable it for a debugging session, not as a permanent default.

### Graphify — default **on**

`setting.graphify_support` — *the one opt-out setting; answer `n` to disable.*

[Graphify](https://pypi.org/project/graphifyy/) builds a per-project code knowledge graph. On every
launch the entrypoint (running **as root**, with the actual work dropped to your UID via `setpriv`)
in the project directory:

- registers an OpenCode skill (`.opencode/skills/graphify/`), a plugin (`.opencode/plugins/graphify.js`,
  rewritten to the V2 format) and a `/graphify` command (`.opencode/command/graphify.md`);
- edits `.opencode/opencode.json` (removes the stale plugin entry, using `jq`);
- builds/refreshes the graph into `graphify-out/` (`--code-only`, no LLM calls, no API key needed).

**Risks — low to medium:**

- **It writes into your project tree** on first launch — new, usually uncommitted files appear in
  `git status`. Decide whether to commit or `.gitignore` `graphify-out/` and `.opencode/`.
- **It runs automatically on whatever project you open**, including a repository you just cloned and
  have not reviewed: the graphify CLI parses that untrusted code at startup, and the injected plugin
  prepends a reminder to the first shell command OpenCode runs. If you work with untrusted
  repositories, disable it.
- The `graphifyy` package is installed from PyPI at image-build time, **unpinned** (see the
  [supply chain table](#what-gets-downloaded-and-where-it-lands-on-path)); it is on `PATH` in the
  image whether or not the setting is on.

### Matt Pocock's agent skills — default off

`setting.matt_pocock_skills_support`

When on, the entrypoint copies the skills staged in the image (`/opt/matt-pocock-skills`) into
`~/.agents/skills` in the container and writes slash-command wrappers into
`<project>/.opencode/command/`. Skills from your host `~/.agents/skills/<name>` win on a name clash
and are then mounted individually (read-only) instead of the whole `~/.agents` directory.

**Risks — low to medium:**

- **Skills are instructions the model follows**, loaded for *every* project. A compromised or
  malicious upstream (`mattpocock/skills`) is a prompt-injection channel with tool access.
- The skills are fetched at **image build time** with `npx skills@latest add mattpocock/skills` —
  unpinned — and are baked into the image **even when this setting is off**; the setting only
  controls whether they are activated. `update` refetches the latest. Review what changed after
  an update if this matters to you.
- It writes wrapper files into the project's `.opencode/command/` (see Graphify above).

### sbt / Coursier / Ivy cache — default off

`setting.sbt_cache_support`, `setting.sbt_cache_dir` (default `~/.cache/opencode-dockerized`)

Because containers use `--rm`, sbt starts cold every time. When on, **private, initially empty**
`sbt`, `coursier` and `ivy2` directories under `sbt_cache_dir` are mounted read-write — but only for
sbt projects (`*.sbt` file or `project/build.properties`). Nothing is copied from the host.

- **Risk — low.** Deliberately designed so the container cannot reach your real `~/.sbt`, Coursier or
  Ivy caches, so it cannot plant a global sbt plugin or a tampered jar that your host sbt would
  later run.
- Residual: the cache is persistent and shared across *all* your sbt projects in containers, so
  something poisoned by one project's build can reach the next project's container (not the host).
  `opencode-dockerized sbt-cache reset` wipes it; `seed` only creates the empty directories.
- Pick a `sbt_cache_dir` that is **not** inside a project you open with this tool, and not a shared
  or world-writable location. `~` is expanded.

### uv package cache — default off

`setting.uv_cache_support`, `setting.uv_cache_dir` (default `~/.cache/opencode-dockerized`)

The same design for Python: a private, initially empty uv cache mounted read-write for Python
projects (`pyproject.toml`, `uv.lock`, `requirements.txt`, `setup.py`, `setup.cfg`, `Pipfile`), plus
`UV_LINK_MODE=copy`. The image's own interpreters and tools in `~/.local/share/uv` are not touched.

- **Risk — low**, with the same residual and mitigations as the sbt cache
  (`opencode-dockerized uv-cache [status|seed|reset]`).

---

## Step 4 — Custom mounts

Prompts: host path → container path (suggested for you) → read-write? (default **no**). Stored as
`mount.<name>=<host>:<container>[:rw]`. Leave the host path empty to finish.

- **Read-only is the default** and the safe choice, but note that **read-only does not mean secret**:
  the agent can read everything you mount and send it anywhere over the host network.
- **Read-write** gives the agent (and `sudo`-root) the ability to modify those host files.

**Risk — depends entirely on the path. Treat these as high:**

| Path | Why |
|---|---|
| `~/.ssh` | Exposes the private keys, even read-only (the prompt even suggests `/home/coder/.ssh` for it). Use [agent forwarding](#ssh-agent-forwarding--default-off) instead. |
| `~/.aws`, `~/.config/gcloud`, `~/.azure`, `~/.kube`, `~/.docker`, `~/.gnupg`, `~/.netrc`, browser profiles, password-manager data | Long-lived credentials and secrets. |
| `$HOME`, `/`, `/etc`, `/var`, other projects | Far wider than the sandbox is meant to be. |
| Anything **read-write** that your shell, desktop or toolchain executes later: `~/.bashrc`, `~/.zshrc`, `~/.profile`, `~/.local/bin`, `~/.config/autostart`, `~/.config/git/hooks`, `~/.gradle/init.d`, `~/.m2/settings.xml` | Persistent **code execution on the host**: planted today, run the next time you open a shell or build. |
| The `opencode-dockerized` checkout itself, read-write | `setup.sh` wires its scripts into your shell (completions, aliases, `PATH`); a container that can edit them executes code on the host the next time you start a shell or the tool. |

Notes:

- The paths are checked for existence; a missing host path gets a warning, and Docker would create
  it as a root-owned directory if you continue.
- `setup.sh` only lets you choose `ro` or `rw`. If you hand-edit the config you may use any Docker
  mount option; note that `z`/`Z` makes Docker **relabel host files** (SELinux) — never use them on
  shared directories.
- Host paths containing `:` are not supported.

---

## Step 5 — Environment variables

Prompts for **names** of variables (`UPPER_SNAKE_CASE`) to pass from your shell into the container.
Only the *name* is stored in the config; the value is read from your environment at each launch and
passed as `-e NAME=value`.

**Risk — medium, depends on the secret:**

- Everything in the container sees them: the agent, every tool it starts, and the LLM context if it
  runs `env`.
- The value is on the `docker run` command line, so it is visible to other local users in `ps` while
  the container runs, and in `docker inspect`.
- A variable that is empty or unset on the host is skipped with a warning.

Pass **scoped, revocable, low-privilege** tokens (a Bedrock key limited to inference, a read-only API
key), never your cloud admin credentials or a general-purpose personal access token.

---

## Step 6 — Shell completions

Appends this line (once) to `~/.bashrc`, `~/.zshrc` or both, plus a `# OpenCode Dockerized completion`
comment:

```bash
[ -f "<repo>/completions/bash.sh" ] && source "<repo>/completions/bash.sh"
```

**Risk — low, with one real caveat:** `source` means those files run **in every interactive shell you
start**, with your full host privileges. The risk is therefore exactly who can write to
`<repo>/completions/`. Keep the checkout owned by you and not group/world-writable, and do not mount it
read-write into the container (including by running the tool *inside the checkout itself* as a
project). The `[ -f … ] &&` guard makes a moved or deleted checkout harmless.

---

## Step 7 — Shell aliases

Appends under a `# OpenCode Dockerized aliases` marker:

```bash
alias ocd='<repo>/opencode-dockerized.sh'
alias ocd-run='<repo>/opencode-dockerized.sh run'
alias ocd-auth='<repo>/opencode-dockerized.sh auth'
```

**Risk — low:** same trust relationship as completions — the aliases run whatever is at
`<repo>/opencode-dockerized.sh`. Unlike completions there is no existence guard, so a moved checkout
leaves dead aliases (harmless, just broken). A repository path containing a single quote (`'`) would
break the alias definition; use a plain path.

---

## Step 8 — Global install

Creates the symlink `~/.local/bin/opencode-dockerized` → `<repo>/opencode-dockerized.sh`.

- An existing **symlink** of that name is replaced (even if it points elsewhere); an existing
  **regular file** is left alone with a warning.
- If `~/.local/bin` is not on your `PATH`, the script appends the following (once) to `~/.zshrc`
  (when you use zsh or the file exists) and `~/.bashrc` — the script runs under bash, so `~/.bashrc`
  is always touched even if you only use zsh:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**Risks — low to medium:**

- The line **prepends** `~/.local/bin`. Whatever is written there shadows system commands (`git`,
  `ls`, `sudo` …). `~/.local/bin` is user-writable by design (pipx, `uv tool`, installers), so this is
  standard practice, but it means that a rw mount of `~/.local` or `$HOME` into the container
  becomes a PATH-hijack vector for the host. Never mount it read-write.
- The symlink points into the repository checkout, so the trust note from steps 6–7 applies again:
  the checkout must only be writable by you.

---

## Summary: risk by choice

| Choice | Default | Risk | Main concern |
|---|---|---|---|
| Existing config: overwrite | — | Low | Silently drops earlier hardening. |
| SSH agent forwarding | off | **Medium** | Container (and `sudo`-root) can use all loaded keys while it runs. |
| LLM interception | off | **Medium–High** | TLS MITM of all container HTTPS; whole `~/.mitmproxy` (incl. CA key) mounted; secrets in traces. |
| &nbsp;&nbsp;↳ capture local | off | Low | Routes loopback (and `pumlsrv`) via the proxy. |
| Graphify | **on** | Low–Medium | Writes into the project; auto-runs on untrusted repos; unpinned PyPI package. |
| Matt Pocock skills | off | Low–Medium | Third-party instructions for the model in every project; unpinned fetch (baked in either way). |
| sbt cache | off | Low | Persistent cache shared across projects (but isolated from the host). |
| uv cache | off | Low | Same as sbt cache. |
| Custom mount, read-only | — | Path dependent | Readable ⇒ exfiltratable. Never secrets. |
| Custom mount, read-write | — | **High** | Host file modification; persistence via rc files / `PATH` dirs. |
| Env variables | none | Medium | Visible to everything in the container, to `ps`, to `docker inspect`. |
| Completions | off | Low | Sourced on every shell start from the checkout. |
| Aliases | off | Low | Run whatever is in the checkout. |
| Global install | off | Low–Medium | `PATH` prepend; symlink into the checkout. |

---

## What gets downloaded, and where it lands on `PATH`

`setup.sh` downloads nothing, but the next step — `opencode-dockerized build` (and `update`, which
busts the cache and refetches the latest of everything) — runs the Dockerfile, which fetches and
executes software from the internet. All of it ends up on the container's `PATH`, runs with the
privileges of `coder` (which has `sudo`), and several items are unpinned or installed via
`curl | bash`.

| Component | Fetched from | Version | Lands in |
|---|---|---|---|
| SDKMAN | `curl https://get.sdkman.io \| bash` | latest installer | `~/.sdkman` |
| Java, Scala | SDKMAN | pinned (`JAVA_VERSION`, Scala 2.13.18) | `~/.sdkman/candidates/java/current/bin` (on `PATH`) |
| sbt | SDKMAN (`sdk install sbt`) | **latest** | `~/.sdkman/candidates/sbt` |
| NVM | `raw.githubusercontent.com/nvm-sh/nvm/<NVM_VERSION>/install.sh` via `curl \| bash` | installer pinned (`v0.40.1`) | `~/.nvm` |
| Node.js | NVM `--lts` | **floating LTS** | `~/.nvm/default` (on `PATH`) |
| uv | `curl https://astral.sh/uv/install.sh \| sh` | **latest** | `~/.local/bin` |
| `graphifyy`, `pytest` | PyPI via `uv` | **unpinned** | `~/.local/bin`, `~/.venv/bin` (first on `PATH`) |
| `@ast-grep/cli` | npm | **unpinned** | NVM bin dir |
| Bun | `curl https://bun.sh/install \| bash` | **latest** | `~/.bun/bin` |
| `pumlsrv` / `pumlcli` | `raw.githubusercontent.com/michael72/pumlsrv/master/get.sh` via `curl \| bash` | **branch `master`, mutable** | installed by that script; `pumlsrv-server` is **started as root** by the entrypoint on every launch |
| OpenCode CLI | npm `@opencode/cli@latest` | **latest** | NVM bin dir |
| Matt Pocock skills | `npx skills@latest add mattpocock/skills` | **latest** | `/opt/matt-pocock-skills` (data, not binaries) |
| Docker CLI, buildx, compose | Docker's apt repository, signed key | latest in repo | `/usr/bin` |

What this means in practice:

- **Anyone who controls one of those upstreams at build time controls code in your container** — and
  therefore, through the baseline above, has a path to root-in-container and to the Docker socket.
  This is the normal supply-chain exposure of installing developer tooling, but it is worth
  stating plainly because several items track `latest`/`master`.
- Rebuilds are not reproducible: two `build`s on different days can differ. If that matters, pin
  versions (`ARG`s / `@x.y.z` / commit SHAs instead of `master`), review `get.sh` before building,
  and build on a trusted network.
- **At run time the agent can do the same thing on its own.** It has unrestricted network access and
  `sudo`; `npm`, `npx`, `bun`, `uv`, `pip` and `apt` all work, plus OpenCode plugins and
  npx-launched MCP servers install from npm into the (host-shared) `~/.npm` cache. Treat every plugin
  or MCP server you add to `~/.config/opencode` as code you are running.
- Because the container is `--rm`, anything installed at run time inside it is gone afterwards
  — *except* what lands in a read-write mount (the project, shared caches, writable config).

---

## A conservative set of answers

If you want the smallest footprint and are happy to trade convenience:

| Prompt | Answer |
|---|---|
| Existing config | Append (and re-check the summary) |
| SSH agent forwarding | **N** — or **Y** only with a dedicated, confirm-on-use key |
| LLM interception | **N** |
| Graphify | **n** if you open untrusted repositories, otherwise your call |
| Matt Pocock skills | **N** |
| sbt / uv cache | **y** where you need it — the private caches are safe by design |
| Custom mounts | none; if needed, read-only and never credentials |
| Environment variables | only scoped, revocable tokens |
| Completions / aliases / global install | **y** is fine as long as the checkout is writable only by you |

And for the parts `setup.sh` cannot change: keep the checkout and your config directory
(`~/.config/opencode-dockerized`) owned by you, rely on `DRY_RUN=true` to audit what a launch mounts,
review `git diff` before committing or building anything the agent touched, and avoid pointing the
tool at untrusted repositories on a machine that holds production credentials.

---

## Undoing what `setup.sh` did

```bash
# Config (settings, mounts, env names)
rm -f ~/.config/opencode-dockerized/config

# Global install
rm -f ~/.local/bin/opencode-dockerized

# Completions, aliases and the PATH line: delete these blocks from ~/.bashrc and ~/.zshrc
#   "# OpenCode Dockerized completion"  + the following source line
#   "# OpenCode Dockerized aliases"     + the three alias lines
#   "# Added by opencode-dockerized setup" + the export PATH line
$EDITOR ~/.bashrc ~/.zshrc

# Docker image
./opencode-dockerized.sh clean
```

The OpenCode directories from [Step 1](#step-1--directories-and-files-no-choice) hold your
credentials and sessions and are not removed by anything above. Delete them yourself only if you
mean to.
