# --- tmux-build: tmux from source with Sixel image support ----------------
# Debian's tmux is built without Sixel, so graphical output (e.g. PlantUML
# diagrams rendered with pumlcli) cannot be shown inside a tmux pane. Sixel is
# only passed on when the outer terminal reports support for it (tmux detects
# this itself). TMUX_VERSION=latest resolves the newest
# release tag via the github.com/.../releases/latest redirect (no API call);
# pass --build-arg TMUX_VERSION=x.y to pin. Only /out/usr/local is copied into
# the final image, so the compiler toolchain stays out of it.
# See: https://github.com/tmux/tmux
FROM debian:bookworm-slim AS tmux-build
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    bison \
    libevent-dev \
    libncurses-dev \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG TMUX_VERSION=latest
# Same cache-busting ARG as below, so './opencode-dockerized.sh update' also
# picks up a new tmux release
ARG OPENCODE_BUILD_TIME=0
WORKDIR /build
RUN version="$TMUX_VERSION" && \
    if [ "$version" = "latest" ]; then \
        latest_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            https://github.com/tmux/tmux/releases/latest)" && \
        version="${latest_url##*/}"; \
    fi && \
    echo "Building tmux ${version} with Sixel support" && \
    curl -fsSL "https://github.com/tmux/tmux/releases/download/${version}/tmux-${version}.tar.gz" \
        | tar -xz --strip-components=1 && \
    ./configure --prefix=/usr/local --enable-sixel && \
    make -j"$(nproc)" && \
    make install-strip DESTDIR=/out && \
    /out/usr/local/bin/tmux -V

# --- final image -------------------------------------------------------------
# Use Debian slim as lightweight Linux base
# Note: We only install Docker CLI to use host's Docker daemon via mounted socket
FROM debian:bookworm-slim

# Parameterize tool versions for easier updates
ARG NVM_VERSION=v0.40.1
ENV JAVA_VERSION=21.0.11-tem \
    JAVA_HOME=/opt/java/openjdk \
    PATH="/opt/java/openjdk/bin:$PATH"

# Install base dependencies and useful CLI tools for coding agents
RUN apt-get update && apt-get install -y \
    git \
    curl \
    bash \
    ca-certificates \
    sudo \
    zip \
    unzip \
    wget \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    ripgrep \
    fd-find \
    jq \
    tree \
    less \
    procps \
    libevent-core-2.1-7 \
    lsof \
    tzdata \
    p11-kit \
    fontconfig \
    locales \
    binutils \
    bc \
    tini \
    xz-utils \ 
    bzip2 \
    graphviz \
    xxd \
    libatomic1 \
    bat \
    libsixel-bin \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/batcat /usr/local/bin/bat
# graphviz and xxd needed by plantuml
# Debian ships bat as 'batcat' (name clash); the symlink also provides 'bat'
# libsixel-bin provides img2sixel, used by puml-show to draw diagrams in the terminal
# libevent-core-2.1-7 is the runtime library of tmux (built from source in tmux-build)
# libatomic1 is dynamically linked by recent official Node.js binaries (installed via nvm below)

RUN update-locale 

# Install Docker CLI only (uses host Docker daemon via mounted socket)
# We don't need docker-ce (daemon) or containerd.io since we use the host's Docker
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user
# Note: Docker socket group membership is handled dynamically in entrypoint.sh
# based on the host's actual Docker socket GID
RUN useradd -m -s /bin/bash -u 1000 coder && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install SDKMAN and Java as coder user
USER coder
WORKDIR /home/coder
RUN curl -s "https://get.sdkman.io" | bash && \
    bash -c "source /home/coder/.sdkman/bin/sdkman-init.sh && \
    sdk install java ${JAVA_VERSION} && \
    sdk default java ${JAVA_VERSION} && \
    sdk install sbt && \
    sdk install scala 2.13.18"

# Install NVM and Node.js LTS as coder user
ENV NVM_DIR="/home/coder/.nvm"
RUN curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash && \
    bash -c "source $NVM_DIR/nvm.sh && \
    nvm install --lts && \
    nvm alias default node && \
    nvm use default && \
    ln -sf \$(dirname \$(which node)) $NVM_DIR/default"

# Install uv (Python package manager) as coder user
# See: https://docs.astral.sh/uv/getting-started/installation/
ENV UV_PROJECT_ENVIRONMENT=/home/coder/.venv
ENV LOCAL_BIN=/home/coder/.local/bin
ENV PATH="${UV_PROJECT_ENVIRONMENT}/bin:$LOCAL_BIN:$PATH"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN uv python install && \
    uv venv ${UV_PROJECT_ENVIRONMENT}

# graphify is used by the graphify skill
RUN uv tool install graphifyy
RUN uv pip install pytest

# Install ast-grep for AST-aware code search/replace (used by oh-my-opencode)
# The npm package @ast-grep/cli provides the 'ast-grep' and 'sg' binaries
# See: https://ast-grep.github.io/
RUN bash -c "source $NVM_DIR/nvm.sh && npm install -g @ast-grep/cli"

# Install Bun (fast JavaScript runtime and package manager)
# Required by oh-my-opencode for optimal performance
# See: https://bun.sh/
RUN curl -fsSL https://bun.sh/install | bash
ENV BUN_INSTALL="/home/coder/.bun"

# Add nvm, node, sdkman, uv, bun, and ast-grep to PATH
# Node.js is available via the NVM default symlink created above
ENV PATH="$BUN_INSTALL/bin:$NVM_DIR/default:/home/coder/.sdkman/candidates/java/current/bin:$PATH"
ENV JAVA_HOME="/home/coder/.sdkman/candidates/java/current"

# install pumlsrv-server + pumlcli for plantuml diagram handling
ENV PUMLSRV_PORT=8380
# install pumlsrv
RUN curl -sSL https://raw.githubusercontent.com/michael72/pumlsrv/master/get.sh | bash

# Install OpenCode V2 globally
# The package postinstall selects the native binary for the platform
# ARG OPENCODE_BUILD_TIME is only passed during 'update' to bust cache
ARG OPENCODE_BUILD_TIME=0
RUN bash -c "source $NVM_DIR/nvm.sh && npm install -g @opencode/cli@latest"

# Switch back to root for entrypoint setup
USER root

# Install git-delta (syntax-highlighting pager for git diff/log/show) from the
# upstream .deb. DELTA_VERSION=latest resolves the newest release tag via the
# github.com/.../releases/latest redirect (no API call, so no rate limit); pass
# --build-arg DELTA_VERSION=x.y.z to pin. The layer sits after the
# OPENCODE_BUILD_TIME ARG, so './opencode-dockerized.sh update' refreshes it.
# See: https://github.com/dandavison/delta
ARG DELTA_VERSION=latest
RUN version="$DELTA_VERSION" && \
    if [ "$version" = "latest" ]; then \
        latest_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            https://github.com/dandavison/delta/releases/latest)" && \
        version="${latest_url##*/}"; \
    fi && \
    arch="$(dpkg --print-architecture)" && \
    echo "Installing git-delta ${version} (${arch})" && \
    curl -fsSL -o /tmp/git-delta.deb \
        "https://github.com/dandavison/delta/releases/download/${version}/git-delta_${version}_${arch}.deb" && \
    apt-get update && \
    apt-get install -y /tmp/git-delta.deb && \
    rm -rf /tmp/git-delta.deb /var/lib/apt/lists/* && \
    delta --version

# tmux with Sixel support, built in the tmux-build stage above
COPY --from=tmux-build /out/usr/local/ /usr/local/
RUN tmux -V

# Matt Pocock's agent skills, staged in the image (opt-in via
# setting.matt_pocock_skills_support — entrypoint.sh copies them into
# ~/.agents/skills at launch when the setting is on).
#
# The upstream installer ('skills', from vercel-labs) always writes a global
# install to $HOME/.agents/skills, so HOME is pointed at the staging directory
# to redirect it. The layer sits after the OPENCODE_BUILD_TIME ARG above, so
# './opencode-dockerized.sh update' refreshes the skills along with OpenCode.
# See: https://github.com/mattpocock/skills
ENV MATT_POCOCK_SKILLS_DIR=/opt/matt-pocock-skills
RUN mkdir -p "$MATT_POCOCK_SKILLS_DIR" && \
    bash -c "source $NVM_DIR/nvm.sh && \
    HOME=$MATT_POCOCK_SKILLS_DIR npx --yes skills@latest add mattpocock/skills \
        --skill '*' --agent opencode --global --yes < /dev/null" && \
    rm -rf "$MATT_POCOCK_SKILLS_DIR/.npm" "$MATT_POCOCK_SKILLS_DIR/.cache" && \
    chmod -R a+rX "$MATT_POCOCK_SKILLS_DIR"

# Create necessary directories with proper permissions
RUN mkdir -p /home/coder/.config/opencode && \
    mkdir -p /home/coder/.local/share/opencode && \
    mkdir -p /home/coder/.local/state/opencode && \
    mkdir -p /home/coder/.cache/opencode && \
    mkdir -p /home/coder/.cache/oh-my-opencode && \
    mkdir -p /home/coder/.gradle && \
    mkdir -p /home/coder/.npm && \
    mkdir -p /home/coder/.m2 && \
    chown -R coder:coder /home/coder

# System-wide tmux settings: the 'tmux' command starts OpenCode inside tmux
# (wrap_in_tmux in config-lib.sh). escape-time 0 keeps Esc instant in the TUI; RGB keeps truecolor
# themes; mouse on forwards scrolling/clicks to OpenCode; passthrough and
# set-clipboard let OSC 52 copy reach the host terminal.
RUN printf '%s\n' \
    'set -s escape-time 0' \
    'set -g default-terminal "tmux-256color"' \
    'set -as terminal-features ",*:RGB"' \
    'set -g mouse on' \
    'set -g focus-events on' \
    'set -g history-limit 50000' \
    'set -g allow-passthrough on' \
    'set -s set-clipboard on' \
    > /etc/tmux.conf

# Default working directory (overridden at runtime by --workdir)
WORKDIR /

# puml-show: render PlantUML in the terminal (pumlcli -> PNG -> img2sixel)
COPY puml-show.sh /usr/local/bin/puml-show
RUN chmod 755 /usr/local/bin/puml-show

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set the entrypoint (runs as root, then switches to coder)
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default command is to run opencode
CMD ["opencode"]
