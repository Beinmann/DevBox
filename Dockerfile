# syntax=docker/dockerfile:1

# Dev box image. Layers are ordered from least- to most-frequently changing
# so that Docker's build cache stays valid as long as possible: base OS +
# apt packages change rarely, the Node runtime occasionally, and the global
# CLI tools (claude, opencode) most often.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC

# ---------------------------------------------------------------------------
# 1. System packages (rarely changes -> top of the file for best caching)
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        # core
        ca-certificates curl wget gnupg openssh-client \
        git git-lfs tmux zsh bash-completion \
        # build toolchain (native deps for python/node packages)
        build-essential pkg-config \
        # python
        python3 python3-dev python3-venv python3-pip pipx \
        # handy CLI dev tools
        ripgrep fd-find fzf jq less tree unzip zip \
        htop vim nano rsync man-db locales sudo \
    && rm -rf /var/lib/apt/lists/*

# fd is installed as `fdfind` on Debian/Ubuntu; expose the conventional name.
RUN ln -s "$(command -v fdfind)" /usr/local/bin/fd

# ---------------------------------------------------------------------------
# 2. Node.js runtime (occasional changes) via NodeSource LTS
# ---------------------------------------------------------------------------
ARG NODE_MAJOR=22
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest

# ---------------------------------------------------------------------------
# 3. uv — fast Python package/venv manager (optional but very handy)
# ---------------------------------------------------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# ---------------------------------------------------------------------------
# 4. Global CLI tooling (changes most often -> bottom, so edits above stay
#    cached and edits here only rebuild this cheap layer)
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.npm \
    npm install -g \
        @anthropic-ai/claude-code \
        opencode-ai

# ---------------------------------------------------------------------------
# Runtime config
# ---------------------------------------------------------------------------
# Home is /root (container always runs as root and /root is bind-mounted from
# the host so all user state — dotfiles, shell history, ~/.claude — persists).
ENV HOME=/root \
    SHELL=/bin/bash \
    EDITOR=vim

# Projects live here; the host ./Everything is bind-mounted onto this path.
WORKDIR /root/Main/Everything

CMD ["bash"]
