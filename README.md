# DevBox

An isolated, on-demand dev container: Ubuntu 24.04 with Python, Node, and a
handful of CLI tools (`claude`, `opencode`, `nvim`, `ripgrep`, `fzf`, `stow`,
`ranger`, …) preinstalled. Always runs as root. State persists across runs
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

1. Builds the image if it isn't already built (`my-dev-box:latest`).
2. On the very first run only, seeds `./root` from the image's built-in
   `/root` (this is what makes `claude`/`opencode`, installed at build time,
   available at runtime — see [Why the wrapper script?](#why-the-wrapper-script)).
3. Starts the container and drops you into a `bash` shell.

Once inside, set up your dotfiles once (they'll persist in `./root` for
every future run) and start `tmux`. This container was built to work with my
personal dotfiles out of the box, which is why `Dockerfile` includes things
like `stow`, `ranger`, and a recent `nvim` build — those are just my
preferences, not requirements. Swap the package list for your own tooling
as needed.

## Usage

```bash
./bash_in_dev_container.sh
```

Every run starts a fresh, throwaway container (`docker compose run --rm`) —
nothing lingers after you exit. Only the bind-mounted directories persist:

| Host path      | Container path              | Contents                                   |
|-----------------|------------------------------|---------------------------------------------|
| `./root`        | `/root`                     | Home dir: dotfiles, shell history, `~/.claude`, caches |
| `./Everything`  | `/root/Main/Everything`     | Your projects (also the container's `WORKDIR`) |

Both are gitignored — nothing under them is ever committed to this repo.

## Why the wrapper script?

`docker compose` won't run directly in this repo — it's gated by a required
env var (`DEV_BOX_WRAPPER`) that only `bash_in_dev_container.sh` sets. This
isn't a security boundary, just a guardrail: calling `docker compose` bare
would skip the first-run seeding step (step 2 above) and silently ship a
container where `claude`/`opencode` are missing, since the image's built-in
`/root` content would otherwise be shadowed by the (initially empty)
`./root` bind mount the moment it's created.

## Rebuilding

```bash
sudo env DEV_BOX_WRAPPER=1 docker compose build
```

Edit the `Dockerfile` to add packages, then rebuild. Layers are ordered
least- to most-frequently-changing for cache efficiency, so most edits only
rebuild the last layer or two.

## Notes

- No network ports are exposed and no host directories other than `./root`
  and `./Everything` are mounted — nothing else on the host is reachable
  from inside the container.
- The image never pulls from a registry under the name `my-dev-box` — Compose
  is configured (`pull_policy: never`) to only build locally.
