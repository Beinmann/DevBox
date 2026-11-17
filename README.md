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
./start.sh
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
./start.sh
```

The container **persists** after you exit the shell — it keeps running in
the background, so anything not covered by the bind mounts (background
processes, a `tmux` session, etc.) survives until you reattach. It does
**not** auto-restart on its own (e.g. after a host reboot). Running the
script again just reattaches a new `bash` shell to the same container; run
it from as many terminals as you like.

Options:

- `-c`, `--run CMD`: run `CMD` in the devbox (`bash -lc`) instead of attaching
  tmux; the script exits with the command's status. Example:
  `./start.sh --run 'ls -la'`.
- `-n`, `--no-enter`: only start the devbox, don't attach interactively.
- `-e`, `--enter`: attach interactively (the default). Reverses `--no-enter`;
  with both, the last one wins. `DEVBOX_ENTER=0` makes `--no-enter` the
  default, and `--enter` then re-enables attaching.
- `--dry-run`: parse the options, print what would happen and exit without
  touching Docker.
- `-h`, `--help`: show the help.

`--run` takes precedence over `--enter`/`--no-enter`.

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
env var (`DEV_BOX_WRAPPER`) that only `start.sh` sets. This
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
./start.sh
```

`docker compose up -d` recreates the container from the updated image since
the image changed.

## Reaching servers inside the container

No ports are published. To open a dev server running in a box from your host
browser, use the sister repo `devbox-proxy` (`../devbox-proxy`): one host
port, a web UI listing your boxes, and any container port at
`http://<port>.<container>.localhost:<proxy port>/`.

- All boxes join one shared Docker network, `devbox-net` (created by
  `start.sh` if missing), which is how the proxy reaches
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
Renaming recreates the sidecar and the box (stop and start). Without a TTY
nothing is asked or saved and the default is used.

HTTPS port mappings chosen with `./tsports.sh` are saved in `./https-ports`
(gitignored, one `HTTPS=TARGET` per line) and re-applied by
`./start.sh` on every start; invalid lines are reported and
skipped. `./tsports.sh --apply` does the same by hand.
`./tsports.sh` keeps prompting (showing the active mappings each round) until
you enter an empty line, then asks to apply the collected changes.

`./tsname.sh` prints the box's full Tailscale DNS name (e.g.
`devbox-general.tapir-perch.ts.net`, no `https://`), for use as
`https://$(./tsname.sh):8443`.

Use the full name for HTTPS ports. Tailscale issues the certificate for the
full MagicDNS name only, so `https://devbox-general/` (short name) fails with
a TLS "internal error" (Firefox: `SSL_ERROR_INTERNAL_ERROR_ALERT`), while
`https://devbox-general.<tailnet>.ts.net/` works. Plain HTTP ports (e.g.
`http://devbox-general:8000`) work with the short name.

If the registration runs out (box open for a long time, or the PC slept),
the sidecar notices within ~30 s and re-registers itself
(`tailscale-renew.sh`, using the key it already has; the box is not
restarted). To do it immediately, run `./tsrenew.sh`: it renews, re-applies
the saved HTTPS ports and prints the node's DNS name.

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
(no TUN device; the start script pulls the image if it's
missing, since the box itself is started with `--pull never`) and makes the box share its network
namespace. The sidecar (not the box) has
`NET_ADMIN` only to reject traffic from the box to `100.64.0.0/10`: without that
rule a box could reach your tailnet devices through the host's own Tailscale
(box, Docker bridge, host, `tailscale0`, arriving as the host), bypassing the
policy above. This also means boxes *without* the sidecar can do that whenever
the host runs Tailscale; to stop it for every container, drop forwarded
traffic to that range on the host, e.g.
`sudo iptables -I DOCKER-USER -d 100.64.0.0/10 -j DROP` (not persistent, and
it affects all Docker containers). Boxes are ephemeral nodes and vanish from the tailnet when they
stop. The node key lives in `./tailscale-state/` (gitignored, sidecar-only
mount), so `./stop_dev_container.sh` leaves no Docker volumes. To update the
sidecar, change the pinned tag in `docker-compose.tailscale.yml` (pick a
release at least two weeks old), then `./stop_dev_container.sh` and start
again. Needs Docker Compose 2.24.4+ (`!reset`, `pull --policy`). While Tailscale is on, the box is not on
`devbox-net`, so `devbox-proxy` cannot reach it. Dev servers that check the
Host header (Vite `allowedHosts`, Django `ALLOWED_HOSTS`) must allow the node
name.

## Docker inside the devbox (Incus only)

For agents that need `docker run` / `docker build` without touching your real
host: run DevBox inside an Incus instance (`security.nesting=true`, Docker
installed in it, `ip-forward-no-drop` in the host's Docker config if the host
also runs Docker) and enable Docker for individual devboxes there:

    ./start.sh --docker       # remembered in ./.devbox-docker (gitignored)
    ./start.sh --no-docker    # turn it off again

With it on, the box gets the instance's `/var/run/docker.sock`, the Docker CLI
(mounted read-only from the instance) and the socket's group (GID read from
the socket). It is per devbox dir, never global.

- **Every start warns and asks `[y/N]`**; without a terminal it refuses.
- **Only inside an Incus/LXC instance** (`systemd-detect-virt` must say
  `lxc`). On a normal host it refuses, since the socket is root-equivalent on
  the machine that owns the daemon. `DEVBOX_DOCKER_ANYWHERE=1` overrides that.
- Anything with the socket controls everything in the same daemon: other
  devboxes of the instance and, if enabled, the Tailscale sidecar (its secret
  and node key). The Incus instance is the isolation boundary, not the box.
- `docker compose` (plugin) is not mounted, only the `docker` CLI.

### Incus host prerequisites

On the host that runs Incus (nftables firewall driver, check with
`sudo incus info | grep -i firewall`):

- Instance created with `security.nesting=true`; Docker installed in it.
- If the host also runs Docker: set `"ip-forward-no-drop": true` in the
  host's `/etc/docker/daemon.json` (and `net.ipv4.ip_forward=1`), or the
  instance has no internet after Docker's FORWARD DROP policy.
- **Keep the instance away from the tailnet and the LAN.** Without this,
  anything in the instance (including a box with Docker access) reaches your
  tailnet devices through the host's own Tailscale (arriving as the host) and
  every device on your LAN, e.g. the router:

      sudo incus network acl create no-tailnet
      sudo incus network acl rule add no-tailnet egress action=reject destination=100.64.0.0/10
      sudo incus network acl rule add no-tailnet egress action=reject destination=fd7a:115c:a1e0::/48
      sudo incus network acl create no-lan
      sudo incus network acl rule add no-lan egress action=reject destination=192.168.0.0/16
      sudo incus network acl rule add no-lan egress action=reject destination=172.16.0.0/12
      sudo incus network set incusbr0 security.acls=no-tailnet,no-lan \
        security.acls.default.egress.action=allow \
        security.acls.default.ingress.action=allow

  The two `default ... allow` settings are needed: once an ACL is attached,
  Incus rejects unmatched traffic and the instance loses its internet.
  Adjust the LAN ranges to your network. Undo with
  `sudo incus network unset incusbr0 security.acls`. Check from inside the
  instance: a TCP connect to a tailnet peer and to your router
  (`timeout 3 bash -c '</dev/tcp/<ip>/<port>'`) must be refused while
  `curl -sI http://archive.ubuntu.com` still answers.
- **Turn IPv6 off on the bridge** (`sudo incus network set incusbr0
  ipv6.address=none`, then restart the instance). If your LAN hands out
  global IPv6, the instance would otherwise reach LAN devices over IPv6
  (NATed to the host's address) past the IPv4 rules above, and an ISP prefix
  is dynamic, so a prefix-based reject rule would silently go stale. The
  instance then runs IPv4-only.
- The instance is unprivileged and shares no host paths, but it shares the
  host kernel; for really hostile code use `incus launch --vm`.

### Published ports and Tailscale

A container the box starts through the instance's Docker publishes `-p`
ports on the *instance*, not in the Tailscale sidecar's network namespace
that the box shares. So such a port is not reachable at the devbox's
tailnet name (servers started directly in the box are), and the LAN is
deliberately cut off (see the ACLs above). Options: a `socat` forwarder in
the box to the instance's Docker bridge gateway, `docker run --network
container:<box>` (no `-p`; dies when the box is recreated), or a Tailscale
node on the instance itself (userspace networking, its own tag, tailnet
policy allowing only your devices), see ticket 043. The instance node exposes
every published port of every container, and a box with the Docker socket
can read its key, so the tailnet policy is the protection.

Setup of the instance node (done on the author's host 2026-11-17, verified):

1. Tailnet policy: add `"tag:incus-docker": ["autogroup:admin"]` to
   `tagOwners` and the tag to the `dst` of the grant that lets your devices
   in (e.g. `"dst": ["autogroup:member", "tag:devbox", "tag:incus-docker"]`).
   There must be no rule with the tag as source and no allow-all rule, so the
   node can reach nothing.
2. Admin console: an OAuth client with only auth-key write access, scoped to
   `tag:incus-docker`.
3. In the instance: install Tailscale (official apt repo), put
   `FLAGS="--tun=userspace-networking"` into `/etc/default/tailscaled` and
   restart `tailscaled` (check `pgrep -a tailscaled` shows the flag).
4. Join: `read -rsp 'secret: ' K; echo; sudo tailscale up
   --auth-key="${K}?preauthorized=true&ephemeral=false"
   --advertise-tags=tag:incus-docker --hostname=incus-docker; unset K`.
5. Test: `docker run -d --rm --name webtest -p 8099:80 nginx:alpine` in the
   instance, then `curl -sI http://incus-docker.<tailnet>:8099` from another
   device answers 200. Outbound must stay blocked: a connect from the
   instance and from a container (`docker run --rm alpine wget ...`) to a
   tailnet peer's `100.x` address is refused.

## Notes

- No ports are published and no host directories other than `./home` and
  `./Everything` are mounted — nothing else on the host is reachable from
  inside the container.
- The image never pulls from a registry under the name `my-dev-box` — Compose
  is configured (`pull_policy: never`) to only build locally.
