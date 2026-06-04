# haggai_computer

<p align="center">
  <img src="docs/screenshot.jpg" alt="A full XFCE Linux desktop running on an Android phone through the RustDesk app" width="820">
  <br>
  <sub><em>One of these desktops — Haggai's — live on his Android phone over RustDesk Direct IP.</em></sub>
</p>

> **Turn one powerful server into many private Linux desktops — one per person —
> each reached over its own RustDesk connection.** Everyone streams pixels from
> anywhere (phone or laptop, even on a thin link); the server does all the compute,
> storage, and downloading. Every desktop is a full, persistent Ubuntu machine,
> isolated from the others and from the host.

Each desktop is a **Docker container** running a real **XFCE desktop**, reached over
**RustDesk** in **Direct IP Access** mode — straight to your box's public IP, with
**no relay, no rustdesk.com account, and no Cloudflare** (sovereign by design). Each
is pre-loaded with a heavy dev / reverse-engineering / data toolchain so **OpenAI
Codex** can do real work and the user can `git push`.

This repository provisions **one such desktop — Haggai's.** He's in a Yeshiva on a
thin link, so he downloads nothing: the big image builds once on this box and he
just streams the screen. Aim it at anyone else and it's their machine instead — and
you can [**run several side by side**](#more-than-one-person) on the same server, one
port each.

---

## Quick start (one desktop)

```bash
./setup.sh '<a-strong-password>'      # >= 12 chars, no control characters
```

That one command builds the image, starts the container, and provisions the
password. The **same password** unlocks **both** RustDesk access **and** the `user`
Linux/sudo login. The first build is **large and slow by design** (full toolchain +
Ghidra + PyTorch + RustDesk + desktop) — let it run; it prints the connect string
when it finishes.

> ⚠️ Each desktop publishes **one** internet-reachable port (this one:
> `0.0.0.0:21128/tcp`) on your DMZ'd box. Add that port to the allow-list in
> [`docs/SECURITY.md`](docs/SECURITY.md) so `verify_network_security.py` stays green.
> That is the only posture change per desktop.

---

## How a user connects (phone + computer)

1. Install **RustDesk** (Android: Play Store / official APK; desktop: rustdesk.com).
2. Use **Direct IP Access** — put
   ```
   <YOUR-PUBLIC-IP>:21128
   ```
   in the ID/peer field and connect. (On the same LAN, use the box's LAN IP, which
   `setup.sh` prints.)
3. Enter the password from setup. You land on the XFCE desktop with full keyboard,
   mouse, and clipboard.

The connection is **straight to your box's IP** — no relay, no account. Capture is
reliable because the desktop is pure **X11/Xorg**, never Wayland (see
`docs/SECURITY.md`), and it **never blanks or locks on idle** — deliberate, so a
remote user never hits a black or locked screen.

---

## First run inside the desktop

Open a terminal (XFCE Terminal) and:

- **OpenAI Codex**
  ```bash
  codex
  ```
  Choose **"Sign in with ChatGPT"** — it prints a URL + device code you open on your
  phone (works on a thin link). Or use an API key:
  ```bash
  export OPENAI_API_KEY='sk-...'      # add to ~/.bashrc to persist
  ```
  Credentials persist in `~/.codex`. Codex ships pre-configured for in-container use
  (`~/.codex/config.toml`, `sandbox_mode = "danger-full-access"`) — see
  `docs/SECURITY.md` for why.

- **GitHub / `git push`**
  ```bash
  gh auth login          # pick the device flow; open the code on your phone
  git config --global user.name  "Your Name"
  git config --global user.email "you@..."
  ```
  Then `git push` works. Auth persists in `~/.config/gh` / `~/.ssh`.

- **`sudo`** uses the same password you set. `sudo apt install <whatever>` works and
  **persists across reboots** (see Persistence).

---

## What's inside (every desktop)

The toolchain is **vendored from `BigBIueWhale/vibe_web_terminal`** (provenance copy
at [`docs/vibe_web_terminal.Dockerfile.reference`](docs/vibe_web_terminal.Dockerfile.reference)),
with its original explanatory comments kept. Highlights:

- **Languages/runtimes:** Python 3 (+ a huge pip stack incl. numpy/pandas/PyTorch
  CPU/transformers), **Node.js 22**, Go, Rust, Ruby, Perl, Lua 5.4, R, Bun, `uv`.
- **Coding agents:** **OpenAI Codex** (primary) and **OpenCode** (available).
- **Build/embedded:** gcc/g++/clang, cmake/ninja/meson, ARM/aarch64 cross, qemu.
- **Reverse engineering:** Ghidra, radare2, binwalk, capstone/lief/pefile, 7zz.
- **Networking/pcap:** nmap, tcpdump, tshark/termshark, scapy, wireshark tooling.
- **Docs/media/OCR:** ffmpeg, imagemagick, pandoc, LibreOffice, tesseract (+ langs),
  Playwright (Chromium+Firefox), and a comprehensive font set.
- **Editors/CLIs:** vim/neovim/emacs/micro, ripgrep/fd/bat/fzf, git/gh, tmux, etc.
- **Desktop GUI apps:** **Firefox**, **Google Chrome**, and **VS Code**, pre-installed
  as real `.deb`s. (Ubuntu 24.04 ships these as *snaps*, and snapd can't run in a
  non-systemd container — so the `.deb` builds are the working path here; `apt install
  firefox` stays pinned to Mozilla's `.deb` too.)

**Deliberately excluded** (your instruction): the **Qwen** CLI and the **Mistral
`vibe`** CLI (and their Ollama/air-gap scaffolding). `ttyd` is built as a tool but
**not served** — these desktops are reached by RustDesk, not a web terminal.

---

## More than one person?

The whole idea: **one server, many desktops.** Each person gets their **own**
container — its own RustDesk port, its own writable system, its own home — and they
**cannot see each other or your host.** They share only the one built image (so the
slow build happens once) and the server's CPU/RAM, which the per-desktop caps
(`cpus 8`, `mem 16g`, `pids 4096`) keep fair.

To add another, give a **fresh copy of this repo** (e.g. another `git clone`, so its
`./home` starts empty) its own **three** unique values, then run its `setup.sh`:

| Make unique per desktop | Where to set it |
|---|---|
| **Name** (e.g. `avi_computer`) | `docker-compose.yml`: the `services:` key, `container_name`, `hostname` — **and** `setup.sh`: `CONTAINER`, `SERVICE` |
| **Host port** (e.g. `21129`) | `docker-compose.yml`: the `ports:` host side — **and** `setup.sh`: `HOST_PORT` |
| **Home dir** | `docker-compose.yml`: the `volumes:` host side (keep it inside that desktop's own folder) |

Everything else (the image, the caps, the whole security posture) stays identical.
Each desktop lands on its own `0.0.0.0:<port>` — add a matching allow-list line in
`docs/SECURITY.md` per port.

> These three are left **explicit per deployment on purpose** (the project's
> "specific, not configurable" rule): you should always know exactly who is on which
> port. There is no hidden multi-tenant launcher to lose track of.

---

## Persistence — each desktop is a real, whole machine

A desktop's container is a long-lived **pet**, not a throwaway:

- **`restart: unless-stopped`** + Docker-on-boot + your BIOS "Restore AC Power Loss
  → Power On" ⇒ after any **reboot or power-cut**, the daemon restarts the **same
  container, writable layer intact**. No action needed.
- So **everything persists** across reboots/restarts — `sudo apt install` packages,
  `/tmp`, `/etc`, `/opt`, any file created anywhere — exactly like a normal computer
  (more so: stock Ubuntu clears `/tmp` on boot; here it doesn't).
- `/home/user` is **additionally** bind-mounted to **`./home`** on the host, so
  personal files persist even more robustly and you can back them up host-side.
- **Don't recreate the container in normal use.** `setup.sh` refuses to run if it
  already exists (so it can't wipe state). To pause/resume use `docker compose stop`
  / `start` — they keep everything.
- The **only** things that reset state are `./teardown.sh` (discards the writable
  layer; keeps `./home`) or a deliberate image rebuild. `./teardown.sh --purge` also
  deletes `./home`.

---

## Lifecycle

| Command | Effect |
|---|---|
| `./setup.sh '<pw>'` | Build + start + provision (first time only; refuses if it already exists). |
| `docker compose stop` / `start` | Pause / resume. Keeps **everything**. |
| `docker compose logs -f` | Watch the desktop / RustDesk logs. |
| `docker compose exec -u user haggai_computer bash` | A shell as `user` inside. |
| `./teardown.sh` | Remove the container (discards apt installs; **keeps `./home`** + image). |
| `./teardown.sh --purge` | Above **and** delete `./home` (typed `DELETE` confirm). |

---

## No NVIDIA, by design

These containers never touch the RTX 5090: no `--gpus`, no NVIDIA runtime, software
(CPU) video encoding only. The card stays free for your own compute.

---

## Reproducibility boundary

- **Pinned** (security-relevant / where upstream pins): RustDesk `1.4.7` (SHA-256
  verified, fail-closed), base `ubuntu:24.04`, Node major `22`, Ghidra (SHA),
  radare2/ttyd commits, libwebsockets tag, `7zip`/`binwalk` versions.
- **Tracking-upstream** (the large apt/pip/npm dev sets, Codex, gh): current-stable
  at build time — matching the upstream Dockerfile and the `personal_server` §16
  "dev toolchain is intentionally unpinned" precedent. A rebuild months later may
  pull newer tool versions; that's deliberate.

See [`docs/SECURITY.md`](docs/SECURITY.md) for the full security posture, the exact
per-port network-audit edit, the shared-password model, and optional extra hardening.
</content>
