# Security posture — haggai_computer

This box is **DMZ-exposed**: the router forwards all ports to it, so the whole
security model is "know exactly what listens on `0.0.0.0`/`::`." This document
records what this project changes and why.

---

## 1. The ONE new internet-reachable port — and the audit edit you must apply

`docker-compose.yml` publishes:

```
0.0.0.0:21128/tcp  ->  container:21118/tcp   (RustDesk Direct IP Access)
```

This is the **only** new externally-reachable listener. It is bound to `0.0.0.0`
(deliberately, so it survives a LAN-IP change) and, because the box is DMZ'd, is
reachable from the public internet at `<public-ip>:21128`. That is the intended
**sovereign** path: Haggai's RustDesk app connects straight to your IP — no relay,
no rustdesk.com, no Cloudflare. On the host it shows up as a `docker-proxy`
listener.

Everything else the container does is **outbound only** (Codex API, `git push`,
`apt`). No new UDP listener; Direct-IP is TCP-only. No host network, no
`docker.sock`, no privileged mode.

**Keep the audit truthful — apply these two edits when you deploy:**

`personal_server/network_security/verify_network_security.py`
```python
EXPECTED_EXTERNAL_TCP_PORTS = {
    22: "OpenSSH Server (sshd)",
    21118: "RustDesk direct IP access",
    21128: "RustDesk (Haggai desktop container, Direct IP)",   # <-- add this line
}
```

`personal_server/network_security/README.md` (§2 table) — add a row:
```
| **21128** | TCP | `docker-proxy` | RustDesk Direct IP Access into Haggai's isolated `haggai_computer` container (host `0.0.0.0:21128` → container `21118`). |
```

After that, `sudo python3 verify_network_security.py` is green again (Section 1's
VMware FAIL remains expected/ignorable, as documented in the personal_server README).

These edits live in the *other* repo, so this project stays self-contained; they
are not applied automatically.

---

## 1a. RustDesk and UDP — why nothing random reaches your external interface

Verified against the RustDesk 1.4.7 source: the "random ephemeral UDP port" that
makes a default-deny UDP firewall impossible for the host's own RustDesk is a
NAT-traversal / rendezvous artifact, and it is **always an outbound socket — there
is no inbound random-UDP listener anywhere in the code**.

- Haggai's **Direct IP Access** connection is a plain **TCP** connect to the
  listener's fixed port (container `21118`, published as `21128`). No UDP, no
  hole-punching — the host is directly reachable, so there is no NAT to traverse.
  (`src/client.rs`: a peer that is an IP returns a `"TCP"` connection immediately;
  the listener is a TCP `listen_any(21118)` in `src/rendezvous_mediator.rs`.)
- Inside the container, `rustdesk --server` still opens (a) an **outbound**
  ephemeral-UDP socket to register with `rs-ny.rustdesk.com:21116`, and (b) a
  **fixed**-port `0.0.0.0:21119/udp` LAN-discovery listener (it opens because the
  binary lives under `/usr`). **Both stay in the container's network namespace and
  are NOT published**, so neither reaches the host's external interface.

Net host-external surface from this project = exactly **`21128/tcp`**. No UDP
allow-list, no ephemeral-range exception — unlike the host's own RustDesk.

> **Sovereignty note:** that outbound rendezvous registration means the container
> *does* phone home to `rs-ny.rustdesk.com` even though your sessions are
> direct-IP. It is outbound-only and does not affect exposure, but if you want zero
> contact with RustDesk's infrastructure, block the container's egress to those
> hosts — the Direct-IP listener keeps working without them.

---

## 2. One password, two uses (your design)

`./setup.sh <password>` sets the **same** value as:

- the RustDesk **permanent password** (unattended access), and
- the `user` **Linux/sudo password**.

So whoever can RustDesk in can also `sudo`. That is intentional — it's Haggai's own
machine. Because port 21128 faces the public internet (DMZ, static IP, no firewall),
pick a STRONG one — long and random, not a guessable word/phrase. The script enforces
only a ≥ 12-char floor; that is a minimum, not a recommendation. It is never stored in
this repo; it is applied at deploy time and asserted (RustDesk: `--password` fired
detached — the 1.4.7 CLI sets the password over IPC and then never exits — then
confirmed by reading it back from `RustDesk.toml`; Linux: `chpasswd` + `passwd -S` → `P`).

---

## 3. Isolation — what the container can and cannot reach

- The **only** host path mounted in is `./home` → `/home/user` (Haggai's home).
  He **cannot** see your files, your RustDesk/SSH/TeamViewer credentials, or
  anything else on the box.
- **No `docker.sock`**, **no `--privileged`**, **no host network**, **no NVIDIA**.
- He cannot open new inbound ports on the host: nothing is published for him beyond
  `21128`, and he has no access to the Docker daemon.
- Resource caps (`cpus 8`, `mem 16g`, `pids 4096`) keep him from starving the
  host's own workloads (e.g. your other GPU/compute containers).

---

## 4. Capabilities & seccomp

Haggai must be able to run `sudo apt install`, so the container runs with
**Docker's default capability set + `SYS_PTRACE`**, and **default seccomp + AppArmor
profiles kept ON**. Two hardening knobs are deliberately NOT used, because each
would break `sudo`/`apt`:

- **`no-new-privileges` is off** — it blocks `sudo` from elevating at all.
- **`cap_drop: ALL` is not used** — it would strip `CHOWN`/`SETUID`/`SETGID`/
  `DAC_OVERRIDE` (so `apt`, `dpkg`, `sudo` fail) and `NET_RAW` (so Haggai's own
  `nmap`/`tcpdump`/`ping` fail).

**Why `SYS_PTRACE` is added — and only that.** RustDesk 1.4.7 sets the unattended
password with a *root* CLI command (`rustdesk --password`) that finds the
user-owned `--server` by reading its `/proc/<pid>/exe`; reading another uid's
`/proc/<pid>/exe` needs `CAP_SYS_PTRACE`, which Docker drops by default — so without
it, provisioning fails ("No --server process found"). `SYS_PTRACE` only lets root
introspect *other processes inside this container*; it is **not** a breakout
primitive.

**What we evaluated and REJECTED.** We never use `seccomp=unconfined` or add
`SYS_ADMIN`. Making this a "real" systemd/logind Ubuntu (so `systemctl` works) would
require booting systemd as PID 1, which on this host needs `SYS_ADMIN` (a documented
breakout primitive) **plus** `apparmor=unconfined` **plus** `cgroupns=host` — and
even then a logind session only forms via an off-label console-getty trick. On a
DMZ-exposed box that posture downgrade is unacceptable, so we keep the lightweight
(supervisor + Xvfb) container and accept that it is a remote **dev desktop**, not a
full systemd OS (no `systemctl`/seat). **If a genuine logind/`systemctl` machine is
ever needed, the posture-consistent answer is a real VM (KVM) — a separate kernel is
*stronger* isolation than any container.** (We also refuse `SYS_ADMIN` /
`seccomp=unconfined` for Codex's nested sandbox; it runs sandbox-less and relies on
the container — see §6.)

**Trust note:** because Haggai is effectively root *inside* his container (via
`sudo`), treat this as "Haggai has root on a well-isolated VM." The blast radius of
anything he does is his container; the host is protected by the boundary above.

---

## 5. Pure X11 — no Wayland portal, no unattended-access patch

The desktop is `Xvfb` + `XFCE` — **X11 end to end, never Wayland**. RustDesk
captures the X server directly, so unattended access is governed solely by the
RustDesk permanent-password config. There is **no `xdg-desktop-portal`
RemoteDesktop/ScreenCast consent dialog** (that only exists on Wayland), so the
`ubuntu_patch_unattended_access` portal auto-approver is **neither used nor
needed** here — and its attack-surface downsides (any flatpak gaining silent
screen-capture) never apply, since we are never on Wayland. This is the
personal_server §0 "stay on Xorg" thesis taken to its conclusion.

---

## 6. Codex sandbox rationale

`~/.codex/config.toml` ships `sandbox_mode = "danger-full-access"`. Codex normally
sandboxes the commands it runs with Landlock + seccomp, but that usually **cannot
initialize inside Docker** and Codex errors out. OpenAI's documented answer for
"Codex inside an already-isolated container" is to disable Codex's own sandbox and
let the **container** be the boundary. We chose this over weakening Docker (no
`SYS_ADMIN`, no `seccomp=unconfined`) — the container is the wall, and the blast
radius is Haggai's own container regardless. Approvals stay at Codex's default so
he still consciously approves actions.

---

## 6a. Browser & VS Code sandboxes — the same call as Codex

Firefox, Chrome, and VS Code are pre-installed as **real `.deb` packages** (Ubuntu
24.04 ships them as *snaps*, and snapd cannot run in this non-systemd container, so
the snap path is a dead end here). Chrome and VS Code are Chromium/Electron: their
renderer sandboxes rely on **unprivileged user namespaces**, which Ubuntu 24.04
blocks by default (`kernel.apparmor_restrict_unprivileged_userns`). Rather than flip
that host-wide sysctl or weaken the container's seccomp (cf. §6), we launch **Chrome
and VS Code with `--no-sandbox`** and let **Firefox** fall back to its seccomp-only
content sandbox. The container is the isolation boundary, exactly as for Codex.

Honest trade-off: with `--no-sandbox`, a renderer exploit (e.g. a malicious web page)
is **not** further confined by the browser's own sandbox — but it is still confined
to Haggai's container (it cannot reach the host or your files). If you want the
in-browser sandbox back, the posture-consistent way is a per-desktop **VM** (a
separate kernel), not loosening this container.

---

## 7. No NVIDIA

No `--gpus`, no NVIDIA container runtime, software video encoding only
(`enable-hwcodec='N'`). The RTX 5090 is never exposed to the container and stays
free for your compute.

---

## 8. Optional further hardening (not enabled — offered)

- **userns-remap:** map container-root to an unprivileged host UID so even
  root-in-container is unprivileged on the host. It's a daemon-wide setting
  (`/etc/docker/daemon.json`) that would affect your other existing containers
  and needs a Docker restart, so it's out of scope here — but it's the
  strongest single hardening if you want it later.
- **WireGuard wrap:** put the RustDesk port behind a self-hosted WireGuard tunnel
  so nothing but an unprobeable WG UDP port is exposed, instead of `21128/tcp`
  directly. More sovereign-secure; one extra app for Haggai.
- **Egress controls:** if you want to limit what the container can reach outbound,
  add firewall rules on the `docker0`/bridge — left open here because Codex and
  `git push` need the internet.
