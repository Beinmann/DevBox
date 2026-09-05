# DevBox

An isolated, on-demand dev container: Ubuntu 24.04 with Python, Node, and a
handful of CLI tools (`claude`, `opencode`, `nvim`, `ripgrep`, `fzf`, `stow`,
`ranger`, …) preinstalled. Runs as an unprivileged user (`dev`), with
passwordless `sudo` available when you need it. State persists across runs
via bind mounts, so it behaves like a real machine rather than a disposable
container — except it's trivial to throw away and rebuild.

## Motivation

Mainly a sandbox for running AI coding agents (Claude Code, opencode) in
auto/YOLO mode without giving them direct access to the host filesystem —
if an agent goes off the rails, the blast radius is the container and the
two mounted directories, not the whole machine. It's also just a clean,
reproducible dev environment: project tooling lives in the image instead of
polluting the host, and rebuilding from scratch is cheap.

## Prerequisites

- Docker + Docker Compose v2, with permission to run `sudo docker`.

## First-time setup

```bash
git clone git@github.com:Beinmann/DevBox.git
cd DevBox
./bash_in_dev_container.sh
```

That single script:

1. Builds the image (`my-dev-box-v2`), passing your host UID/GID as build
   args so the container's `dev` user matches you and files it creates land
   with your ownership on the host. Docker's layer cache makes this a fast
   no-op when the Dockerfile and build args haven't changed since the last
   build.
2. On the very first run only, seeds `./home` from the image's built-in
   `/home/dev` (this is what makes `claude`/`opencode`, installed at build
   time, available at runtime — see [Why the wrapper script?](#why-the-wrapper-script)).
3. Starts the container and drops you into a `bash` shell as `dev`.

Once inside, set up your dotfiles once (they'll persist in `./home` for
every future run) and start `tmux`. This container was built to work with my
personal dotfiles out of the box, which is why `Dockerfile` includes things
like `stow`, `ranger`, and a recent `nvim` build — those are just my
preferences, not requirements. Swap the package list for your own tooling
as needed.

## Usage

```bash
./bash_in_dev_container.sh
```

The container **persists** after you exit the shell — it keeps running in
the background, so anything not covered by the bind mounts (background
processes, a `tmux` session, etc.) survives until you reattach. It does
**not** auto-restart on its own (e.g. after a host reboot). Running the
script again just reattaches a new `bash` shell to the same container; run
it from as many terminals as you like.

To tear the container down when you're done with it:

```bash
./stop_dev_container.sh
```

This removes the container (`docker compose down`), so nothing lingers in
`docker ps -a`. Only the bind-mounted directories persist across a stop:

| Host path      | Container path              | Contents                                   |
|-----------------|------------------------------|---------------------------------------------|
| `./home`        | `/home/dev`                 | Home dir: dotfiles, shell history, `~/.claude`, caches |
| `./Everything`  | `/home/dev/Main/Everything` | Your projects (also the container's `WORKDIR`) |

Both are gitignored — nothing under them is ever committed to this repo.

Each clone of this repo is its own independent Compose project (Compose
derives the project name from the directory), so you can run multiple
devboxes side by side — from different directories — without them
interfering with each other.

Inside the container, `dev` can run any command via `sudo` with no password
prompt (e.g. `sudo apt-get install ...`). This isn't a security boundary —
see the note in `Dockerfile` — but it does mean anything you run *without*
an explicit `sudo` (the vast majority of day-to-day commands, including
whatever an AI agent runs on its own) is unprivileged by default.

**Upgrading an existing clone:** if you have a `./root` directory from
before this change, it's no longer bind-mounted and won't be used going
forward. Manually copy over anything you want to keep (dotfiles, `~/.claude`,
etc.) into the new `./home` — `./root` itself is left alone, so nothing is
lost, but it's dead weight you can delete once you've migrated what you need.

## Why the wrapper script?

`docker compose` won't run directly in this repo — it's gated by a required
env var (`DEV_BOX_WRAPPER`) that only `bash_in_dev_container.sh` sets. This
isn't a security boundary, just a guardrail: calling `docker compose` bare
would skip the first-run seeding step (step 2 above) and silently ship a
container where `claude`/`opencode` are missing, since the image's built-in
`/home/dev` content would otherwise be shadowed by the (initially empty)
`./home` bind mount the moment it's created.

## Rebuilding

```bash
sudo env DEV_BOX_WRAPPER=1 docker compose build \
  --build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)"
```

Edit the `Dockerfile` to add packages, then rebuild. Layers are ordered
least- to most-frequently-changing for cache efficiency, so most edits only
rebuild the last layer or two.

Rebuilding the image doesn't affect an already-running container — it keeps
running on the old image until you stop and start it again:

```bash
./stop_dev_container.sh
./bash_in_dev_container.sh
```

`docker compose up -d` recreates the container from the updated image since
the image changed.

## Notes

- No network ports are exposed and no host directories other than `./home`
  and `./Everything` are mounted — nothing else on the host is reachable
  from inside the container.
- The image never pulls from a registry under the name `my-dev-box` — Compose
  is configured (`pull_policy: never`) to only build locally.
