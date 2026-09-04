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
    tmux \
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
    && rm -rf /var/lib/apt/lists/*
# graphviz and xxd needed by plantuml

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

# Install OpenCode and OpenSpec globally
# OpenSpec: Spec-driven development (SDD) for AI coding assistants
# See: https://github.com/Fission-AI/OpenSpec/
# ARG OPENCODE_BUILD_TIME is only passed during 'update' to bust cache
ARG OPENCODE_BUILD_TIME=0
RUN bash -c "source $NVM_DIR/nvm.sh && npm install -g opencode-ai@latest @fission-ai/openspec@latest"

# Switch back to root for entrypoint setup
USER root

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
    mkdir -p /home/coder/.config/openspec && \
    mkdir -p /home/coder/.local/share/opencode && \
    mkdir -p /home/coder/.cache/opencode && \
    mkdir -p /home/coder/.cache/oh-my-opencode && \
    mkdir -p /home/coder/.cache/openspec && \
    mkdir -p /home/coder/.gradle && \
    mkdir -p /home/coder/.npm && \
    mkdir -p /home/coder/.m2 && \
    chown -R coder:coder /home/coder

# Default working directory (overridden at runtime by --workdir)
WORKDIR /

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set the entrypoint (runs as root, then switches to coder)
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default command is to run opencode
CMD ["opencode"]
