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
        ripgrep fd-find fzf jq less tree unzip zip moreutils \
        htop vim nano rsync man-db locales sudo \
        # required by dotfilesv3 (base/ai/nvim/vim/scripts modules)
        stow ranger bc \
    && rm -rf /var/lib/apt/lists/*

# fd is installed as `fdfind` on Debian/Ubuntu; expose the conventional name.
RUN ln -s "$(command -v fdfind)" /usr/local/bin/fd

# ---------------------------------------------------------------------------
# 1b. Unprivileged dev user. UID/GID default to 1000:1000 (the typical
#     first-user UID on Linux) but are meant to be overridden at build time
#     with the actual host user's UID/GID, so files created in the container
#     end up owned by the host user instead of some arbitrary container UID.
#     Full passwordless sudo is intentional here, not an oversight: this is a
#     disposable, isolated dev box (no exposed ports, only two bind mounts —
#     see devbox/README.md), not a security boundary. What it does buy is a
#     safer default posture — anything run without an explicit `sudo` is
#     unprivileged, so accidental damage (a stray `rm -rf /`, a misbehaving
#     install script) is contained to what `dev` can touch.
# ---------------------------------------------------------------------------
ARG USER_UID=1000
ARG USER_GID=1000

# Ubuntu's base image ships a preexisting `ubuntu` user/group at 1000:1000
# (for cloud-init) which collides with the default (and most common host)
# USER_UID/USER_GID of 1000 — remove it first so groupadd/useradd below
# don't fail with "GID/UID already exists".
RUN userdel -r ubuntu 2>/dev/null; groupdel ubuntu 2>/dev/null; true

RUN groupadd --gid "$USER_GID" dev \
    && useradd --uid "$USER_UID" --gid "$USER_GID" --create-home --shell /bin/bash dev \
    && passwd -d dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

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
#
# Installed under $HOME=/opt/... (not root's actual home) and symlinked into
# /usr/local/bin, so the `dev` user isn't blocked from following the symlink
# by root's home directory being 0700.
RUN HOME=/opt/claude-install curl -fsSL https://claude.ai/install.sh | bash -s latest \
    && chmod -R a+rX /opt/claude-install \
    && ln -s /opt/claude-install/.local/bin/claude /usr/local/bin/claude
RUN HOME=/opt/opencode-install curl -fsSL https://opencode.ai/install | bash \
    && chmod -R a+rX /opt/opencode-install \
    && ln -s /opt/opencode-install/.opencode/bin/opencode /usr/local/bin/opencode

RUN claude --version && opencode --version

# ---------------------------------------------------------------------------
# Runtime config
# ---------------------------------------------------------------------------
# Container runs as the unprivileged `dev` user, whose home is bind-mounted
# from the host so all user state — dotfiles, shell history, ~/.claude —
# persists.
ENV HOME=/home/dev \
    SHELL=/bin/bash \
    EDITOR=vim

USER dev

# Projects live here; the host ./Everything is bind-mounted onto this path.
WORKDIR /home/dev/Main/Everything

CMD ["bash"]
