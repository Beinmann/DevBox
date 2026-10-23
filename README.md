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

## Reaching servers inside the container

No ports are published. To open a dev server running in a box from your host
browser, use the sister repo `devbox-proxy` (`../devbox-proxy`): one host
port, a web UI listing your boxes, and any container port at
`http://<port>.<container>.localhost:<proxy port>/`.

- All boxes join one shared Docker network, `devbox-net` (created by
  `bash_in_dev_container.sh` if missing), which is how the proxy reaches
  them by container name. Side effect: boxes can also reach *each other*
  on that network, so they're not network-isolated from one another.
- **Dev servers must listen on `0.0.0.0`**, not just `localhost`/`127.0.0.1`,
  or the proxy gets connection refused. Many tools default to localhost-only
  (Vite: `--host 0.0.0.0`; Next: `-H 0.0.0.0`; Flask: `--host 0.0.0.0`;
  `python -m http.server` already binds all interfaces).

## Reaching servers over Tailscale

Optional. With it, each devbox joins your tailnet as its own node, named
`devbox-<short name>-<3 random chars>`, and every port a server in the box listens on —
including `127.0.0.1`-only ones — is reachable as `http://<node name>:<port>`
from your other tailnet devices and from the host (which needs the Tailscale
client). Plain HTTP only; the traffic is already WireGuard-encrypted.

On the first interactive start the script asks once whether to set it up; the
answer is kept in `~/.config/devbox/` (outside the repo and `./home`), so it
is not asked again for other boxes or clones. Declined or unset, the box
starts as without it: no sidecar, nothing in the repo.

The first time Tailscale is enabled for a devbox dir you are asked for the
short name, with a preview of the final node name (default: the sanitized dir
name, or the parent dir's name if the dir is just `devbox`). It is kept in
`./.devbox-tailscale-name` (gitignored); delete that file to be asked again.
Renaming recreates the sidecar and the box (stop and start). The 3-char
suffix is generated once and kept in `./tailscale-state/`. Without a TTY
nothing is asked or saved and the default is used.

One-time tailnet setup (admin console):

1. Define `tag:devbox` (owner `autogroup:admin`) and replace the default
   allow-all policy, so that your own devices may reach `tag:devbox` but
   nothing lets a devbox start a connection:
   ```json
   {
     "tagOwners": { "tag:devbox": ["autogroup:admin"] },
     "grants": [
       { "src": ["autogroup:member"], "dst": ["autogroup:member", "tag:devbox"], "ip": ["*"] }
     ]
   }
   ```
2. Create an OAuth client with only the `auth_keys` (write) scope and the tag
   `tag:devbox`. Give its secret to the script when asked, or write
   `TS_AUTHKEY=<secret>?ephemeral=true&preauthorized=true` to
   `~/.config/devbox/tailscale.env` (mode 600). Never put it in the repo or
   `./home`; the box can't read it (only the sidecar gets it).

How it works: `docker-compose.tailscale.yml` (added with `-f` only when the
secret file exists) runs a `tailscale/tailscale` sidecar in userspace mode
(no `NET_ADMIN`, no TUN device; the start script pulls the image if it's
missing, since the box itself is started with `--pull never`) and makes the box share its network
namespace. Boxes are ephemeral nodes and vanish from the tailnet when they
stop. The node key lives in `./tailscale-state/` (gitignored, sidecar-only
mount), so `./stop_dev_container.sh` leaves no Docker volumes. To update the
sidecar, change the pinned tag in `docker-compose.tailscale.yml` (pick a
release at least two weeks old), then `./stop_dev_container.sh` and start
again. Needs Docker Compose 2.24.4+ (`!reset`, `pull --policy`). While Tailscale is on, the box is not on
`devbox-net`, so `devbox-proxy` cannot reach it. Dev servers that check the
Host header (Vite `allowedHosts`, Django `ALLOWED_HOSTS`) must allow the node
name.

## Notes

- No ports are published and no host directories other than `./home` and
  `./Everything` are mounted — nothing else on the host is reachable from
  inside the container.
- The image never pulls from a registry under the name `my-dev-box` — Compose
  is configured (`pull_policy: never`) to only build locally.
