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

pumlsrv-server &

# Use setpriv to drop privileges and exec the command as the mapped user
# cd into the project working directory before executing
exec setpriv --reuid="$TARGET_UID" --regid="$TARGET_GID" --init-groups \
    bash -c "source \$NVM_DIR/nvm.sh && source /home/coder/.sdkman/bin/sdkman-init.sh 2>/dev/null || true && cd \"$WORKDIR\" && exec \"\$@\"" \
    -- "$@"
