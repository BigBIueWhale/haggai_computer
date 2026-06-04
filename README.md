# haggai_computer

A full **XFCE Linux desktop in a Docker container**, reached over **RustDesk**
(Direct IP Access — no relay, sovereign), pre-loaded with a heavy
dev / reverse-engineering / data toolchain so **OpenAI Codex** can do real work
and Haggai can `git push`. The image builds on this powerful box; Haggai only
streams pixels, so he downloads nothing on his thin Yeshiva link.

It behaves like a **real, persistent Ubuntu machine**: `sudo apt install`, files,
`/tmp`, `/etc` — everything survives reboots. He drives it from his **Android
phone** and his **computer** with the same RustDesk app.

---

## Quick start

```bash
./setup.sh '<a-strong-password>'      # >= 12 chars
```

That one command builds the image, starts the container, and sets the password.
The **same password** is used for **both** RustDesk access **and** the `user`
Linux/sudo login. The first build is **large and slow by design** (full toolchain
+ Ghidra + PyTorch + RustDesk + desktop) — let it run.

When it finishes it prints the connect string.

> ⚠️ This publishes **one** new internet-reachable port (`0.0.0.0:21128/tcp`) on
> this DMZ'd box. Apply the one-line audit allow-list edit in
> [`docs/SECURITY.md`](docs/SECURITY.md) so `verify_network_security.py` stays
> green. That's the only posture change.

---

## How Haggai connects (phone + computer)

1. Install **RustDesk** (Android: Play Store / the official APK; desktop: rustdesk.com).
2. In RustDesk, use **Direct IP Access**: enter
   ```
   <YOUR-PUBLIC-IP>:21128
   ```
   in the ID/peer field and connect. (On the same LAN you can use the box's LAN
   IP instead — `setup.sh` prints it.)
3. Enter the password from setup. He lands on the XFCE desktop with full keyboard,
   mouse, and clipboard.

No relay, no rustdesk.com account, no Cloudflare — the connection is **straight to
your box's IP**. (RustDesk's screen capture is reliable here precisely because the
desktop is pure **X11/Xorg**, never Wayland — see `docs/SECURITY.md`.)

---

## First run inside the desktop

Open a terminal (XFCE Terminal) and:

- **OpenAI Codex**
  ```bash
  codex
  ```
  Choose **"Sign in with ChatGPT"** — it prints a URL + device code you open on
  your phone (works on a thin link). Or use an API key:
  ```bash
  export OPENAI_API_KEY='sk-...'      # add to ~/.bashrc to persist
  ```
  Credentials persist in `~/.codex` (his home is persistent).
  Codex is pre-configured for in-container use (`~/.codex/config.toml`,
  `sandbox_mode = "danger-full-access"`) — see `docs/SECURITY.md` for why.

- **GitHub / `git push`**
  ```bash
  gh auth login          # pick the device flow; open the code on your phone
  git config --global user.name  "Haggai ..."
  git config --global user.email "haggai@..."
  ```
  Then `git push` works. Auth persists in `~/.config/gh` / `~/.ssh`.

- **`sudo`** uses the same password you set. `sudo apt install <whatever>` works
  and **persists across reboots** (see Persistence below).

---

## What's inside

The toolchain is **vendored from `BigBIueWhale/vibe_web_terminal`** (a provenance
copy is at [`docs/vibe_web_terminal.Dockerfile.reference`](docs/vibe_web_terminal.Dockerfile.reference)),
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

**Deliberately excluded** (your instruction): the **Qwen** CLI and the **Mistral
`vibe`** CLI (and their Ollama/air-gap scaffolding). `ttyd` is built as a tool but
**not served** (we use RustDesk, not a web terminal).

---

## Persistence — it's a real, whole machine

The container is a long-lived **pet**, not a throwaway:

- **`restart: unless-stopped`** + Docker-on-boot + your BIOS "Restore AC Power Loss
  → Power On" ⇒ after any **reboot or power-cut**, the daemon restarts **this same
  container, with its full writable layer intact**. No action needed.
- So **everything persists** across reboots/restarts — `sudo apt install` packages,
  `/tmp`, `/etc`, `/opt`, any file or folder Haggai creates anywhere — exactly like
  a normal computer (in fact more so: stock Ubuntu clears `/tmp` on boot; here it
  doesn't).
- `/home/user` is **additionally** bind-mounted to **`./home`** on the host, so his
  personal files persist even more robustly and you can back them up from the host.
- **Do not recreate the container in normal use.** `setup.sh` refuses to run if it
  already exists (so it can't wipe his state). To pause/resume use
  `docker compose stop` / `docker compose start` — these keep everything.
- The **only** things that reset state are `./teardown.sh` (discards the writable
  layer; keeps `./home`) or a deliberate image rebuild. `./teardown.sh --purge`
  also deletes `./home`.

---

## Lifecycle

| Command | Effect |
|---|---|
| `./setup.sh '<pw>'` | Build + start + provision (first time only; refuses if it already exists). |
| `docker compose stop` / `start` | Pause / resume. Keeps **everything**. |
| `docker compose logs -f` | Watch the desktop/RustDesk logs. |
| `docker compose exec -u user haggai_computer bash` | A shell as `user` inside. |
| `./teardown.sh` | Remove the container (discards apt installs; **keeps `./home`** + image). |
| `./teardown.sh --purge` | Above **and** delete `./home` (typed `DELETE` confirm). |

---

## No NVIDIA, by design

This container never touches the RTX 5090: no `--gpus`, no NVIDIA runtime, software
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
network-audit edit, the shared-password model, and optional extra hardening.
