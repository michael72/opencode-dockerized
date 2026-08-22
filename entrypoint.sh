#!/bin/bash
set -euo pipefail

# This script runs as root and handles UID/GID mapping before switching to coder user

# Fix Docker socket permissions if mounted from host
if [ -S /var/run/docker.sock ]; then
    DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock)

    # Create or use existing group with matching GID
    if ! getent group "$DOCKER_SOCK_GID" >/dev/null 2>&1; then
        groupadd -g "$DOCKER_SOCK_GID" docker_host 2>/dev/null || true
    fi

    # Add coder user to the docker socket's group for access
    usermod -aG "$DOCKER_SOCK_GID" coder 2>/dev/null || true
fi

# Get target UID/GID from environment (default to 1000)
TARGET_UID=${HOST_UID:-1000}
TARGET_GID=${HOST_GID:-1000}

# Get current coder user UID/GID
CURRENT_UID=$(id -u coder)
CURRENT_GID=$(id -g coder)

# Update UID/GID if they don't match
if [ "$TARGET_UID" != "$CURRENT_UID" ] || [ "$TARGET_GID" != "$CURRENT_GID" ]; then
    echo "Adjusting coder user UID:GID from $CURRENT_UID:$CURRENT_GID to $TARGET_UID:$TARGET_GID"

    # Update group ID if needed
    if [ "$TARGET_GID" != "$CURRENT_GID" ]; then
        groupmod -g "$TARGET_GID" coder 2>/dev/null || true
    fi

    # Update user ID if needed
    if [ "$TARGET_UID" != "$CURRENT_UID" ]; then
        usermod -u "$TARGET_UID" coder 2>/dev/null || true
    fi

    # Fix ownership of essential home directory contents only
    # Avoid full recursive chown on NVM/SDKMAN trees which can be very slow
    echo "Fixing home directory permissions..."
    chown "$TARGET_UID:$TARGET_GID" /home/coder 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.config 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.local 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.cache 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.npm 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.gradle 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.m2 2>/dev/null || true
    chown -R "$TARGET_UID:$TARGET_GID" /home/coder/.bun 2>/dev/null || true
    # NVM and SDKMAN: only fix top-level ownership, not deeply nested files
    chown "$TARGET_UID:$TARGET_GID" /home/coder/.nvm 2>/dev/null || true
    chown "$TARGET_UID:$TARGET_GID" /home/coder/.sdkman 2>/dev/null || true
fi

# NOTE: We do NOT change ownership of the project directory
# The project mount is a host bind-mount and should maintain host permissions
# OpenCode runs as the host user (via UID/GID mapping) so it already has the right permissions

# Resolve the project working directory (set by opencode-dockerized.sh)
# Falls back to /workspace for backward compatibility
WORKDIR="${OPENCODE_WORKDIR:-/}"

# Switch to coder user and execute the command
# Set HOME explicitly to ensure it points to /home/coder
export HOME=/home/coder
export USER=coder

# Source NVM and SDKMAN to make Node.js and Java available
export NVM_DIR="/home/coder/.nvm"

# Auto-initialize OpenSpec for the project if enabled and not yet initialized
# Runs 'openspec init --tools opencode --profile core' in the project directory when:
#   1. OPENSPEC_SUPPORT=true (set by opencode-dockerized config)
#   2. No openspec/ directory exists in the project yet
#   3. The openspec CLI is available in the image
# Then runs 'openspec update' to regenerate instruction files for the current CLI version.
# The update also runs on already-initialized projects to keep files in sync after upgrades.
if [ "${OPENSPEC_SUPPORT:-false}" = "true" ]; then
    if command -v openspec >/dev/null 2>&1 || [ -x "$NVM_DIR/default/bin/openspec" ]; then
        if [ ! -d "$WORKDIR/openspec" ]; then
            echo "OpenSpec: initializing project with OpenCode tool integration..."
            setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
                bash -c "source \$NVM_DIR/nvm.sh && cd \"$WORKDIR\" && openspec init --tools opencode --profile core" 2>/dev/null || \
                echo "OpenSpec: init failed (non-fatal) — you can run 'openspec init --tools opencode --profile core' manually"
        fi
        # Update instruction files to match the current CLI version (idempotent)
        setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
            bash -c "source \$NVM_DIR/nvm.sh && cd \"$WORKDIR\" && openspec update" 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# Graphify: per-project knowledge-graph skill (idempotent)
#
# Enabled by default, opt out via setting.graphify_support=false.
#
# The 'graphify' CLI is installed globally in the image (Dockerfile), but
# everything it registers is per-project, so it belongs here rather than baked
# into the image — the project mount is writable, ~/.config/opencode is not:
#   - not yet registered for this project (.opencode/skills/graphify/ missing)
#     -> register the skill project-scoped and build the graph for the first time
#   - registered by an older graphify (image was updated)
#     -> re-register so SKILL.md matches the CLI, then refresh the graph
#   - already registered and current -> just refresh the graph incrementally
#
# Two things the graphify CLI does not do on its own and that are added below:
#   - GRAPH_REPORT.md: a build stops at graph.json + .graphify_analysis.json.
#     The human-readable report (and the community clustering it summarises) is
#     only written by 'graphify cluster-only'.
#   - /graphify: OpenCode has no such command. 'graphify opencode install'
#     writes a *skill*, which the model may call as a tool, while slash commands
#     come from {command,commands}/**/*.md — so the command file is written here.
# ---------------------------------------------------------------------------
if [ "${GRAPHIFY_SUPPORT:-true}" = "true" ] && command -v graphify >/dev/null 2>&1; then
    GRAPHIFY_SKILL_DIR="$WORKDIR/.opencode/skills/graphify"
    GRAPHIFY_COMMAND_FILE="$WORKDIR/.opencode/command/graphify.md"

    # Version stamp written by 'graphify opencode install --project'; comparing it
    # against the CLI in the image detects a skill left behind by an older image.
    GRAPHIFY_CLI_VERSION=$(graphify --version 2>/dev/null | awk '{print $NF}' || true)
    GRAPHIFY_SKILL_VERSION=""
    if [ -f "$GRAPHIFY_SKILL_DIR/.graphify_version" ]; then
        GRAPHIFY_SKILL_VERSION=$(cat "$GRAPHIFY_SKILL_DIR/.graphify_version" 2>/dev/null || true)
    fi

    if [ ! -d "$GRAPHIFY_SKILL_DIR" ]; then
        echo "Graphify: registering OpenCode skill for this project..."
        setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
            bash -c "cd \"$WORKDIR\" && graphify opencode install --project" 2>/dev/null || \
            echo "Graphify: skill registration failed (non-fatal) — run 'graphify opencode install --project' manually"

        echo "Graphify: building initial knowledge graph..."
        setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
            bash -c "cd \"$WORKDIR\" && graphify . --code-only " || \
            echo "Graphify: initial build failed (non-fatal) — run 'graphify .' manually"
    else
        if [ -n "$GRAPHIFY_CLI_VERSION" ] && [ "$GRAPHIFY_SKILL_VERSION" != "$GRAPHIFY_CLI_VERSION" ]; then
            echo "Graphify: skill is from ${GRAPHIFY_SKILL_VERSION:-an unknown version}, image ships $GRAPHIFY_CLI_VERSION — re-registering..."
            setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
                bash -c "cd \"$WORKDIR\" && graphify opencode install --project" 2>/dev/null || \
                echo "Graphify: skill refresh failed (non-fatal) — run 'graphify opencode install --project' manually"
        fi

        echo "Graphify: refreshing knowledge graph (incremental update)..."
        setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
            bash -c "cd \"$WORKDIR\" && graphify . --code-only --update" || \
            echo "Graphify: update failed (non-fatal) — run 'graphify . --update' manually"
    fi

    # GRAPH_REPORT.md + graph.html from the graph that was just written.
    # '--no-label' leaves communities as "Community N" instead of calling an LLM
    # to name them, which keeps startup free of API keys, tokens and network —
    # the same reason the build above uses '--code-only'. To name them, run
    # 'graphify label .' inside the container once a provider is configured.
    if [ -f "$WORKDIR/graphify-out/graph.json" ]; then
        echo "Graphify: writing graphify-out/GRAPH_REPORT.md..."
        setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
            bash -c "cd \"$WORKDIR\" && graphify cluster-only . --no-label" || \
            echo "Graphify: report generation failed (non-fatal) — run 'graphify cluster-only . --no-label' manually"
    fi

    # /graphify slash command. OpenCode reads commands from
    # {command,commands}/**/*.md under the project's .opencode/ and under its
    # config dir; the latter is mounted read-only, so the project copy is the
    # only writable option. Written once — edits to the file are kept.
    if [ ! -f "$GRAPHIFY_COMMAND_FILE" ]; then
        echo "Graphify: adding the /graphify command for OpenCode..."
        mkdir -p "$WORKDIR/.opencode/command"
        cat > "$GRAPHIFY_COMMAND_FILE" <<'GRAPHIFY_COMMAND_EOF'
---
description: Build or query this project's graphify knowledge graph
---

Use the `graphify` skill to answer this request.

Arguments: $ARGUMENTS

If no arguments were given, summarise the existing graph: read
`graphify-out/GRAPH_REPORT.md` and run `graphify god-nodes`.

The graph already exists at `graphify-out/` — the container builds it on first
launch and refreshes it on every start, so there is no need to run a full build.
Query it instead of grepping raw files:

- `graphify query "<question>"` — scoped subgraph for a question
- `graphify path "<A>" "<B>"` — shortest path between two nodes
- `graphify explain "<X>"` — plain-language explanation of a node
- `graphify affected "<X>"` — what a change to X reaches
- `graphify god-nodes` — the most connected nodes
- `graphify . --code-only --update` — re-index after editing files

Communities are unnamed (`Community N`) because the startup build runs without
an LLM. `graphify label .` names them once a provider is configured.

Do not answer from raw files before consulting the graph.
GRAPHIFY_COMMAND_EOF
        # Written as root (privileges drop only at the exec below), so hand the
        # command file and any directory just created back to the host user.
        chown "$TARGET_UID:$TARGET_GID" \
            "$WORKDIR/.opencode" "$WORKDIR/.opencode/command" "$GRAPHIFY_COMMAND_FILE" 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# LLM traffic interception (opt-in via setting.llm_interceptor_support)
#
# 'lli watch' runs on the HOST — containers use --network host, so the proxy is
# reachable on loopback. All this needs to do is (a) trust the host's mitmproxy
# CA and (b) export the proxy variables for the process we exec below.
# ---------------------------------------------------------------------------
if [ "${LLM_INTERCEPTOR_SUPPORT:-false}" = "true" ]; then
    LLI_PORT="${LLM_INTERCEPTOR_PORT:-9090}"
    LLI_CA="/home/coder/.mitmproxy/mitmproxy-ca-cert.pem"

    # Trusting the CA must happen here, as root, before privileges are dropped.
    if [ -f "$LLI_CA" ]; then
        install -m 0644 "$LLI_CA" /usr/local/share/ca-certificates/mitmproxy.crt
        update-ca-certificates >/dev/null 2>&1 || true

        # The system store covers curl/git/openssl. These cover the runtimes that
        # ship their own bundle and ignore it.
        export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mitmproxy.crt
        export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
        export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    else
        echo "llm-interceptor: no CA at $LLI_CA — HTTPS interception will fail."
        echo "  Run 'lli watch' once on the host to generate ~/.mitmproxy, then relaunch."
    fi

    # Both variables point at the SAME proxy endpoint. HTTP_PROXY selects it for
    # http:// targets, HTTPS_PROXY for https:// targets (tunnelled via CONNECT to
    # that same port) — they are not two ports and not two protocols.
    export HTTP_PROXY="http://127.0.0.1:${LLI_PORT}"
    export HTTPS_PROXY="http://127.0.0.1:${LLI_PORT}"
    export http_proxy="$HTTP_PROXY"
    export https_proxy="$HTTPS_PROXY"

    # By default keep container-local services off the proxy — notably pumlsrv on
    # ${PUMLSRV_PORT:-8380}. This matters because bun's fetch() *does* proxy
    # 127.0.0.1 unless it is listed here (curl skips loopback on its own).
    #
    # A local model (llama-server, ollama) also lives on loopback, so capturing it
    # means giving up that exemption entirely: NO_PROXY matches on host, not port,
    # so there is no way to route :8080 through the proxy while sparing :8380.
    # Routing pumlsrv through the proxy is harmless, but it does mean pumlsrv stops
    # working when 'lli watch' is not running.
    if [ "${LLM_INTERCEPTOR_CAPTURE_LOCAL:-false}" = "true" ]; then
        export NO_PROXY="${LLM_INTERCEPTOR_NO_PROXY:-}"
    else
        export NO_PROXY="${LLM_INTERCEPTOR_NO_PROXY:-localhost,127.0.0.1,::1}"
    fi
    export no_proxy="$NO_PROXY"

    echo "llm-interceptor: routing through $HTTP_PROXY (NO_PROXY=${NO_PROXY:-<none>})"

    # lli only *records* URLs matching its filter; by default that is a regex
    # allowlist of hosted providers (api.anthropic.com, api.openai.com, ...).
    # Everything else — including any local model — is proxied and shown in lli's
    # request summary but never written to traces/. Local endpoints therefore need
    # an explicit glob, which '--include' accepts repeatably.
    if [ "${LLM_INTERCEPTOR_CAPTURE_LOCAL:-false}" = "true" ]; then
        echo "llm-interceptor: loopback is proxied — start lli with a matching glob, e.g."
        echo "  lli watch --include '*127.0.0.1*' --include '*localhost*'"
        echo "  (its built-in allowlist covers hosted providers only, not local models)"
    fi
fi

pumlsrv-server &

# Use setpriv to drop privileges and exec the command as the mapped user
# cd into the project working directory before executing
exec setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
    bash -c "source \$NVM_DIR/nvm.sh && source /home/coder/.sdkman/bin/sdkman-init.sh 2>/dev/null || true && cd \"$WORKDIR\" && exec \"\$@\"" \
    -- "$@"
