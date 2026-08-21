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
        git git-lfs git-credential-oauth tmux zsh bash-completion \
        # build toolchain (native deps for python/node packages)
        build-essential pkg-config \
        # python
        python3 python3-dev python3-venv python3-pip pipx \
        # handy CLI dev tools
        ripgrep fd-find fzf jq less tree unzip zip \
        htop vim nano rsync man-db locales sudo \
        # required by dotfilesv3 (base/ai/nvim/vim/scripts modules)
        stow ranger bc \
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
# 3b. Neovim (official static build — Ubuntu 24.04's apt package, 0.9.x, is
#     too old for kickstart.nvim-style configs which expect 0.10+)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz \
        -o /tmp/nvim.tar.gz \
    && tar -C /opt -xzf /tmp/nvim.tar.gz \
    && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim \
    && rm /tmp/nvim.tar.gz

# ---------------------------------------------------------------------------
# 4. Global CLI tooling (changes most often -> bottom, so edits above stay
#    cached and edits here only rebuild this cheap layer)
# ---------------------------------------------------------------------------
# Installed via their native installers (not npm) — claude-code's native
# binary ships as an npm optionalDependency that BuildKit's build network
# was silently failing to fetch (npm treats optional-dep failures as
# non-fatal, so `npm install` succeeded while shipping a broken stub). The
# native installers fetch the platform binary directly, sidestepping that.
RUN curl -fsSL https://claude.ai/install.sh | bash -s latest \
    && ln -s /root/.local/bin/claude /usr/local/bin/claude
RUN curl -fsSL https://opencode.ai/install | bash \
    && ln -s /root/.opencode/bin/opencode /usr/local/bin/opencode

RUN claude --version && opencode --version

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
