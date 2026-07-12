# Immutable Image Updates

This is the Cloud Run-style deployment path for this desktop: the host trusts one
configured image repository, and GitHub Actions can ask the host to deploy a new
digest from that repository.

The webhook never gets to choose an arbitrary image. It can only say:

```json
{
  "desktop": "haggai_computer",
  "image": "natanfreeman/docker-computer",
  "digest": "sha256:..."
}
```

The host accepts that request only when the HMAC is valid and both `desktop` and
`image` exactly match `/etc/haggai/deployer.toml`.

## Persistence Model

Image updates are immutable. The deployer stops and removes the old container,
then starts a new container from:

```text
natanfreeman/docker-computer@sha256:...
```

Only the configured home directory persists:

```text
/opt/haggai/haggai_computer/home -> /home/user
```

Packages installed inside the old container with `sudo apt install ...` do not
survive an image update. Put long-lived system changes in the image repo instead.

Because `/etc/shadow` is part of the recreated container, the deployer needs the
desktop password in a root-owned host file. It reprovisions both:

- RustDesk permanent password
- the `user` Linux/sudo password

## Host Install

On the host:

```bash
sudo install -d -m 0700 /etc/haggai /usr/local/lib/haggai /opt/haggai/haggai_computer/home
sudo install -m 0755 deploy/haggai_image_webhook.py /usr/local/lib/haggai/haggai_image_webhook.py
sudo install -m 0644 deploy/haggai-image-webhook.service /etc/systemd/system/haggai-image-webhook.service
sudo install -m 0600 deploy/haggai-deployer.example.toml /etc/haggai/deployer.toml
sudoedit /etc/haggai/deployer.toml
```

Create the three root-owned secret files referenced by the config:

```bash
sudo sh -c 'umask 077; printf "%s\n" "THE_DESKTOP_PASSWORD" > /etc/haggai/haggai-password'
sudo sh -c 'umask 077; printf "%s\n" "DOCKERHUB_READONLY_TOKEN" > /etc/haggai/dockerhub-readonly-token'
sudo sh -c 'umask 077; openssl rand -hex 32 > /etc/haggai/webhook-secret'
```

The registry token should be read-only for the configured Docker Hub repository.
Do not use a broad personal token.

## First Deploy

After your image exists in Docker Hub, deploy one digest manually:

```bash
sudo /usr/local/lib/haggai/haggai_image_webhook.py \
  --config /etc/haggai/deployer.toml \
  deploy \
  --digest sha256:PUT_THE_IMAGE_DIGEST_HERE
```

This replaces any existing container with the configured `container_name`. The
old container writable layer is discarded; the configured home directory is kept.
The repository's `./teardown.sh` can remove either the legacy Compose-managed
container or the immutable-image container by name.

## Webhook Service

Start the webhook:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now haggai-image-webhook.service
sudo journalctl -u haggai-image-webhook.service -f
```

By default it listens only on:

```text
http://127.0.0.1:8828/deploy
```

Expose it through a TLS reverse proxy, tunnel, or other authenticated edge. The
HMAC prevents unauthorized deploys, but TLS prevents replayable signed requests
from being observed in transit.

## GitHub Actions

Copy `deploy/github-actions-deploy.example.yml` into the image repo as:

```text
.github/workflows/deploy.yml
```

Set these GitHub Actions secrets:

```text
DOCKERHUB_USERNAME=NatanFreeman
DOCKERHUB_TOKEN=<Docker Hub access token with write access to natanfreeman/docker-computer>
HAGGAI_WEBHOOK_URL=https://YOUR-HOST.example.com/deploy
HAGGAI_WEBHOOK_SECRET=<contents of /etc/haggai/webhook-secret>
```

The workflow builds and pushes `IMAGE:stable`, takes the pushed digest, signs the
payload with:

```text
HMAC_SHA256(secret, timestamp + "." + raw_json_body)
```

and sends:

```text
X-Haggai-Timestamp: <unix seconds>
X-Haggai-Signature: sha256=<hex hmac>
```

The host then pulls with the read-only registry token and runs the image by digest,
never by mutable tag.

The deployer also reads the pulled image's `org.haggai.published-ports` label and
publishes those host ports. To add a new preview port to future immutable deploys,
change that label in the Dockerfile and rebuild the image; no host TOML edit is
needed unless you want a host-only override.

## Rollback

If the new container fails to start, fails health, fails password provisioning, or
does not publish the configured host port, the deployer removes it and tries to
restart the previous image reference. Rollback still uses the immutable model, so
it restores the previous image, not the old container writable layer.
