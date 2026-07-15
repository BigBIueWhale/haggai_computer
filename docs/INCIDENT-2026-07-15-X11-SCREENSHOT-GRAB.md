# Incident report: an X11 screenshot grab blocked RustDesk

- **Date:** 2026-07-15
- **Affected container:** `haggai_computer`
- **Affected display:** Xvfb `:99`
- **User-visible impact:** the KDE desktop and RustDesk remote screen-control
  connections stopped responding
- **Container impact:** none; the container remained running and did not restart
- **Times below:** Israel Daylight Time (`UTC+03:00`)

## Summary

At 21:11:41, a Codex agent running through T3 Code attempted to capture a
transient **Open Folder** window with ImageMagick `import`. The window had already
disappeared, so its X11 window ID was stale. `import` reported `BadWindow`, but a
stranded `import` process remained connected to the shared Xvfb display while
retaining an X11 server grab.

An X11 server grab gives one client exclusive access to the X server. While the
grab was held, Xvfb `:99` remained alive and kept its Unix socket open, but it did
not process normal requests from KDE, RustDesk, D-Bus autolaunch helpers, or new
diagnostic X11 clients. RustDesk therefore could not enumerate or capture the
display or initialize a replacement connection-manager UI. Its TCP listener
remained bound, so Docker continued to report the container as healthy even
though remote desktop sessions could not work.

The stranded `import` process later disappeared without a container, Xvfb, or
RustDesk-server restart. X11 automatically releases a server grab when its owning
client disconnects. Once that happened, `:99` resumed processing requests and a
later RustDesk reconnect recreated the connection manager and screen-capture
pipeline.

## Triggering operation

The operation came from a Codex app-server session launched by T3 Code while it
was exercising the LLM Wiki graphical interface. The agent ran:

```sh
xdotool windowactivate 0x0a20003f key ctrl+l
xdotool type --delay 10 -- /tmp
xdotool key Return
sleep 2
import -window 0x0a20003f /tmp/open-folder-tmp.png
```

The decisive command was:

```sh
import -window 0x0a20003f /tmp/open-folder-tmp.png
```

Earlier window enumeration had identified `0x0a20003f` as **Open Folder**. By the
time the capture ran, that transient dialog no longer existed. The command logged:

```text
X Error of failed request:  BadWindow (invalid Window parameter)
Resource id in failed request:  0xa20003f
import-im6.q16: no window with specified ID exists `0x0a20003f'
```

The requested `/tmp/open-folder-tmp.png` was never created. Despite reporting the
error, this process remained alive:

```text
PID     PPID     STARTED   COMMAND
1073443 1055275  21:11:41  import -window 0x0a20003f /tmp/open-folder-tmp.png
```

Its parent, PID `1055275`, was a Codex app-server process descended from T3 Code.
The process used display `:99`, which is the same shared Xvfb display that KDE and
RustDesk use.

## Evidence that the screenshot process held the X server grab

During the outage:

- `Xvfb :99` was alive and sleeping in its normal event loop.
- `xdpyinfo -display :99` timed out.
- The same check against the independent test display `:100` succeeded.
- Xvfb's listening socket `/tmp/.X11-unix/X99` remained present.
- Xvfb's epoll state had ordinary client reads disabled while retaining input
  service for the ImageMagick `import` connection. The Xvfb endpoint for that
  connection was file descriptor `89`, socket inode `48572429`; its peer was
  socket inode `48564803`, file descriptor `4` in PID `1073443`.
- A `wmctrl -l` query against `:99` remained stuck.
- Every newly launched RustDesk `--cm` process became stranded beside a
  `dbus-launch --autolaunch` helper. D-Bus autolaunch consults X11, so these
  helpers could not complete while the display was grabbed.

This combination distinguishes a grabbed X server from a stopped container, a
dead Xvfb process, an unavailable X11 socket, or general host resource exhaustion.

## Incident timeline

| Israel time | Event |
|---|---|
| 21:09:51 | Window enumeration shows `0x0a20003f` as **Open Folder**. |
| 21:11:41 | The Codex-launched `import` process starts against that window ID. |
| 21:11:44 | `import` reports that the window no longer exists, but the process remains alive and the X11 grab remains held. |
| 21:15:03 | The active RustDesk desktop session begins unwinding; clipboard, audio, and display services exit or reset. |
| 21:15:04 | RustDesk accepts reconnect `#1015`, but the desktop-login path cannot complete its X11 display work. |
| 21:15:05 | The RustDesk connection manager reports `Failed to send audio data: Broken pipe`. |
| 21:16:28 | RustDesk connections reset. The existing Flutter connection-manager UI closes and emits invalid GTK window/widget and missing-engine warnings. |
| 21:16:28–21:17:24 | Rapid reconnects launch replacement `rustdesk --cm` processes, but none can create the `ipc_cm` listener. RustDesk reports `Failed to connect to connection manager` and drops some back-pressured connections. |
| 21:17:24 | The final reconnect before the long stall logs peer encoding information and then blocks before completing display initialization. |
| 21:17–21:38 | Client retries accumulate while TCP port `21118` remains bound. The RustDesk listener exists, but it cannot provide a usable desktop. |
| 21:38 onward | The server begins draining and rejecting TCP retries again, but the desktop remains unavailable while the X11 grab persists. |
| Between 21:41:36 and 21:47:17 | The stranded `import` process disappears. No explicit `kill` command, OOM kill, container restart, Xvfb restart, or RustDesk-server restart is recorded. The available evidence cannot distinguish an eventual ImageMagick exit from command-runner cleanup/reaping. |
| 21:47:17 | A RustDesk reconnect successfully enumerates the display, creates its XDO context, and starts the display capture service. |
| 21:47:18 | A replacement connection manager creates `/tmp/RustDesk-1000/ipc_cm` and accepts the session IPC connection. Remote control works again. |

RustDesk's timestamps are logged in UTC; the entries around `18:15` through
`18:47` UTC correspond to `21:15` through `21:47` Israel time.

## Why RustDesk failed even though its port remained open

RustDesk has two relevant layers:

1. Its direct-IP TCP server listens on container port `21118`.
2. A successful remote-control session must also initialize the connection
   manager and query/capture the X11 display.

The screenshot incident disabled the second layer, not necessarily the first.
RustDesk could retain the listening socket and accept or queue some TCP
connections while being unable to obtain display information, capture frames, or
start its connection-manager UI. Repeated client reconnects produced secondary
symptoms:

- `Failed to connect to connection manager`
- `R-T3: writer channel full — dropping the back-pressured connection`
- `Forward reset by the peer`
- multiple stranded `rustdesk --cm` and `dbus-launch` processes

The Compose healthcheck did not detect the failure because it checks only for the
listening socket:

```yaml
healthcheck:
  test: ["CMD-SHELL", "ss -ltn | grep -q ':21118 '"]
```

Thus, Docker's `healthy` state meant only that port `21118` was bound. It did not
prove that Xvfb was responsive or that RustDesk could establish a screen-control
session.

## Recovery

The recovery was automatic after the grab-owning X11 client disappeared:

```text
stuck import process exits or is reaped
              ↓
X11 closes its client connection and releases the server grab
              ↓
Xvfb :99 resumes servicing KDE and RustDesk
              ↓
RustDesk's next reconnect creates a working --cm process and ipc_cm socket
              ↓
screen capture and remote control resume
```

The following processes retained their original lifetimes throughout the outage
and recovery:

- container `haggai_computer`: no restart; Docker restart count `0`
- `Xvfb :99`: original PID `17`
- `rustdesk --server`: original PID `659929`

The precise reason the `import` process finally disappeared was not recorded. No
explicit kill operation appeared in the relevant Codex sessions, and the kernel
recorded no OOM kill for this period. It is therefore intentionally described as
"exited or was reaped," not attributed to an unobserved mechanism.

## Unrelated resource-limit event earlier that day

At 14:56:48, more than six hours before this incident, the container reached its
16 GiB memory cgroup limit. The kernel killed a T3 Code process. At 15:00:47 the
container also briefly reached its 4,096-PID/task cgroup limit and rejected a
fork.

Those resource limits are explicitly defined by this repository in
`docker-compose.yml`:

```yaml
cpus: 8.0
mem_limit: 16g
memswap_limit: 16g
pids_limit: 4096
```

There was no new OOM kill, PID-limit rejection, Docker stop, or kernel failure in
the 21:11–21:47 incident window. The earlier resource-pressure event is therefore
not the cause of this RustDesk outage.

## Safe screenshot procedure

### Preferred: use an application-native screenshot API

For automated browser or UI tests, use the application's own screenshot
facility—for example, Playwright's `page.screenshot()`. An application-native
capture does not take an X11 server-wide grab and is not coupled to a transient
desktop window ID.

### Whole Xvfb display: use bounded FFmpeg `x11grab`

To capture the shared `1920x1080` Xvfb desktop, use a read-only X11 capture with a
hard deadline:

```sh
timeout --kill-after=1s 5s \
  ffmpeg -hide_banner -loglevel error \
  -f x11grab -video_size 1920x1080 -i :99.0 \
  -frames:v 1 -y /tmp/screenshot.png
```

### Specific window: validate, capture a region, and impose a deadline

Window IDs are short-lived. Resolve and validate the window immediately before
capture, obtain its geometry, and capture that screen region with FFmpeg. Do not
reuse a window ID obtained minutes earlier.

At minimum, validate a selected ID before doing anything else:

```sh
win="$(xdotool search --onlyvisible --name '^LLM Wiki$' | tail -n1)"
test -n "$win"
timeout --kill-after=1s 2s xwininfo -id "$win" >/dev/null
```

Then use its current geometry as the `x11grab` input region, with a timeout around
the entire capture operation.

### Isolate GUI tests from the remotely controlled display

If a test genuinely needs desktop automation or ImageMagick `import`, run the
test application on a separate disposable Xvfb display such as `:100`, not the
shared RustDesk/KDE display `:99`. A failure can then freeze only the test display,
not the user's remote desktop. A timeout is still required.

### Prohibited pattern on the shared display

Do not run an unbounded ImageMagick capture against a transient window on `:99`:

```sh
# Unsafe on the shared RustDesk display:
import -window "$possibly_stale_window_id" /tmp/screenshot.png
```

ImageMagick `import` may use an X11 server grab to create a consistent window
image. If its invalid-window or disappearing-window path hangs while the grab is
held, every GUI client sharing that display can become unusable. If `import` is
unavoidable, use a disposable Xvfb display, revalidate the window immediately,
and wrap the command in a strict timeout.

## Operational lessons

- A live X11 socket does not prove that the X server is servicing clients.
- A live RustDesk TCP listener does not prove that screen capture or connection
  management works.
- GUI automation must not share RustDesk's production display unless every
  operation is bounded and known not to take a server-wide grab.
- Transient window IDs must never be cached and reused without revalidation.
- Screenshot commands need explicit deadlines and cleanup behavior.
- RustDesk health monitoring should eventually verify an X11 round trip and
  connection-manager readiness in addition to checking port `21118`.
