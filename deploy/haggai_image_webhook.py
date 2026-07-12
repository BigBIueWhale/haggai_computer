#!/usr/bin/env python3
"""
Host-side immutable image deployer for haggai_computer.

The trusted image repository is configured on the host. The webhook may only
request a new sha256 digest for that already-approved repository.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import hmac
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Ubuntu 24.04 has Python 3.12.
    print("Python 3.11+ is required for tomllib.", file=sys.stderr)
    raise


DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
RUSTDESK_PASSWORD_TIMEOUT = 420
RUSTDESK_PASSWORD_REFIRE = 20
POLL_SLEEP = 3
LINUX_PASSWORD_TIMEOUT = 60
IMAGE_PUBLISHED_PORTS_LABEL = "org.haggai.published-ports"


class DeployError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class ServerConfig:
    listen_host: str
    listen_port: int
    max_body_bytes: int
    signature_tolerance_seconds: int


@dataclasses.dataclass(frozen=True)
class PortConfig:
    host_port: int
    container_port: int
    protocol: str
    host_ip: str | None = None
    description: str = ""


@dataclasses.dataclass(frozen=True)
class DesktopConfig:
    name: str
    image: str
    container_name: str
    hostname: str
    home_dir: Path
    host_port: int
    container_port: int
    password_file: Path
    extra_ports: list[PortConfig]


@dataclasses.dataclass(frozen=True)
class RuntimeConfig:
    cpus: str
    memory: str
    memory_swap: str
    pids_limit: int
    shm_size: str
    health_timeout_seconds: int


@dataclasses.dataclass(frozen=True)
class RegistryConfig:
    host: str
    username: str
    token_file: Path


@dataclasses.dataclass(frozen=True)
class WebhookConfig:
    secret_file: Path


@dataclasses.dataclass(frozen=True)
class Config:
    server: ServerConfig
    desktop: DesktopConfig
    runtime: RuntimeConfig
    registry: RegistryConfig
    webhook: WebhookConfig


def log(message: str) -> None:
    print(f"[haggai-deploy] {message}", flush=True)


def _table(root: dict[str, Any], name: str) -> dict[str, Any]:
    value = root.get(name)
    if not isinstance(value, dict):
        raise DeployError(f"config missing [{name}] table")
    return value


def _required_str(table: dict[str, Any], key: str, label: str) -> str:
    value = table.get(key)
    if not isinstance(value, str) or not value.strip():
        raise DeployError(f"config value {label}.{key} must be a non-empty string")
    return value.strip()


def _optional_str(table: dict[str, Any], key: str, default: str) -> str:
    value = table.get(key, default)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    if not isinstance(value, str) or not value.strip():
        raise DeployError(f"config value {key} must be a non-empty string")
    return value.strip()


def _optional_int(table: dict[str, Any], key: str, default: int) -> int:
    value = table.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise DeployError(f"config value {key} must be an integer")
    return value


def _required_int(table: dict[str, Any], key: str, label: str) -> int:
    value = table.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise DeployError(f"config value {label}.{key} must be an integer")
    return value


def _required_path(table: dict[str, Any], key: str, label: str) -> Path:
    value = _required_str(table, key, label)
    path = Path(value)
    if not path.is_absolute():
        raise DeployError(f"config value {label}.{key} must be an absolute path")
    return path


def _port_number(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise DeployError(f"config value {label} must be an integer")
    if value < 1 or value > 65535:
        raise DeployError(f"config value {label} must be between 1 and 65535")
    return value


def _parse_port_configs(raw_ports: Any, label: str) -> list[PortConfig]:
    if not isinstance(raw_ports, list):
        raise DeployError(f"{label} must be an array of tables")

    ports: list[PortConfig] = []
    seen: set[tuple[str | None, int, str]] = set()
    for index, raw in enumerate(raw_ports, start=1):
        item_label = f"{label}[{index}]"
        if not isinstance(raw, dict):
            raise DeployError(f"{item_label} must be a table")
        protocol = raw.get("protocol", "tcp")
        if protocol not in ("tcp", "udp"):
            raise DeployError(f"{item_label}.protocol must be tcp or udp")
        host_ip = raw.get("host_ip")
        if host_ip is not None and (not isinstance(host_ip, str) or not host_ip.strip()):
            raise DeployError(f"{item_label}.host_ip must be a non-empty string")
        host_ip = host_ip.strip() if host_ip is not None else None
        if host_ip == "0.0.0.0":
            host_ip = None
        description = raw.get("description", "")
        if not isinstance(description, str):
            raise DeployError(f"{item_label}.description must be a string")
        port = PortConfig(
            host_port=_port_number(raw.get("host_port"), f"{item_label}.host_port"),
            container_port=_port_number(raw.get("container_port"), f"{item_label}.container_port"),
            protocol=protocol,
            host_ip=host_ip,
            description=description.strip(),
        )
        key = (port.host_ip, port.host_port, port.protocol)
        if key in seen:
            raise DeployError(f"{item_label} duplicates a previous host port mapping")
        seen.add(key)
        ports.append(port)
    return ports


def _parse_extra_ports(desktop: dict[str, Any]) -> list[PortConfig]:
    raw_ports = desktop.get("extra_ports", [])
    return _parse_port_configs(raw_ports, "config value desktop.extra_ports")


def load_config(path: Path) -> Config:
    with path.open("rb") as handle:
        raw = tomllib.load(handle)

    server = raw.get("server", {})
    if server and not isinstance(server, dict):
        raise DeployError("config [server] must be a table")

    desktop = _table(raw, "desktop")
    runtime = raw.get("runtime", {})
    if runtime and not isinstance(runtime, dict):
        raise DeployError("config [runtime] must be a table")
    registry = _table(raw, "registry")
    webhook = _table(raw, "webhook")

    registry_host = _required_str(registry, "host", "registry")
    image = _required_str(desktop, "image", "desktop")
    if "@" in image:
        raise DeployError("desktop.image must be a repository name, not an image@digest reference")
    docker_hub_short_name = registry_host == "docker.io" and image.count("/") == 1
    if not docker_hub_short_name and not image.startswith(f"{registry_host}/"):
        raise DeployError("desktop.image must live under registry.host")

    name = _required_str(desktop, "name", "desktop")
    container_name = desktop.get("container_name", name)
    if not isinstance(container_name, str) or not container_name.strip():
        raise DeployError("desktop.container_name must be a non-empty string")
    hostname = desktop.get("hostname", container_name.replace("_", "-"))
    if not isinstance(hostname, str) or not hostname.strip():
        raise DeployError("desktop.hostname must be a non-empty string")

    memory = _optional_str(runtime, "memory", "16g")

    return Config(
        server=ServerConfig(
            listen_host=_optional_str(server, "listen_host", "127.0.0.1"),
            listen_port=_optional_int(server, "listen_port", 8828),
            max_body_bytes=_optional_int(server, "max_body_bytes", 4096),
            signature_tolerance_seconds=_optional_int(
                server, "signature_tolerance_seconds", 300
            ),
        ),
        desktop=DesktopConfig(
            name=name,
            image=image,
            container_name=container_name.strip(),
            hostname=hostname.strip(),
            home_dir=_required_path(desktop, "home_dir", "desktop"),
            host_port=_port_number(_required_int(desktop, "host_port", "desktop"), "desktop.host_port"),
            container_port=_optional_int(desktop, "container_port", 21118),
            password_file=_required_path(desktop, "password_file", "desktop"),
            extra_ports=_parse_extra_ports(desktop),
        ),
        runtime=RuntimeConfig(
            cpus=_optional_str(runtime, "cpus", "8.0"),
            memory=memory,
            memory_swap=_optional_str(runtime, "memory_swap", memory),
            pids_limit=_optional_int(runtime, "pids_limit", 4096),
            shm_size=_optional_str(runtime, "shm_size", "1g"),
            health_timeout_seconds=_optional_int(runtime, "health_timeout_seconds", 300),
        ),
        registry=RegistryConfig(
            host=registry_host,
            username=_required_str(registry, "username", "registry"),
            token_file=_required_path(registry, "token_file", "registry"),
        ),
        webhook=WebhookConfig(
            secret_file=_required_path(webhook, "secret_file", "webhook")
        ),
    )


def read_secret(path: Path, label: str, *, min_len: int = 1) -> str:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise DeployError(f"could not read {label} at {path}: {exc}") from exc
    raw = raw.rstrip(b"\r\n")
    if len(raw) < min_len:
        raise DeployError(f"{label} at {path} is empty or too short")
    if b"\n" in raw or b"\r" in raw:
        raise DeployError(f"{label} at {path} must be a single line")
    try:
        value = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise DeployError(f"{label} at {path} must be UTF-8 text") from exc
    return value


def read_password(path: Path) -> str:
    password = read_secret(path, "desktop password", min_len=12)
    if any(ord(char) < 32 or ord(char) == 127 for char in password):
        raise DeployError("desktop password must not contain control characters")
    return password


def run(
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        args,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        env=env,
    )
    if check and proc.returncode != 0:
        output = (proc.stdout or "").strip()
        suffix = f"\n{output}" if output else ""
        raise DeployError(f"command failed ({proc.returncode}): {' '.join(args)}{suffix}")
    return proc


def assert_host_preconditions() -> None:
    for command in ("docker", "ss"):
        if shutil.which(command) is None:
            raise DeployError(f"required command not found on PATH: {command}")
    run(["docker", "info"], capture=True)


def image_ref(config: Config, digest: str) -> str:
    if not DIGEST_RE.fullmatch(digest):
        raise DeployError("digest must be sha256:<64 lowercase hex chars>")
    return f"{config.desktop.image}@{digest}"


def docker_login_and_pull(config: Config, ref: str) -> None:
    token = read_secret(config.registry.token_file, "registry token", min_len=8)
    with tempfile.TemporaryDirectory(prefix="haggai-docker-config-") as docker_config:
        env = os.environ.copy()
        env["DOCKER_CONFIG"] = docker_config
        log(f"logging into {config.registry.host} with the read-only deploy token")
        run(
            [
                "docker",
                "login",
                config.registry.host,
                "--username",
                config.registry.username,
                "--password-stdin",
            ],
            env=env,
            input_text=f"{token}\n",
            capture=True,
        )
        log(f"pulling {ref}")
        run(["docker", "pull", ref], env=env)


def inspect_container(name: str) -> dict[str, Any] | None:
    proc = subprocess.run(
        ["docker", "container", "inspect", name],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if proc.returncode != 0:
        return None
    try:
        inspected = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise DeployError(f"docker inspect returned invalid JSON for {name}") from exc
    if not inspected:
        return None
    return inspected[0]


def inspect_image(ref: str) -> dict[str, Any]:
    proc = run(["docker", "image", "inspect", ref], capture=True)
    try:
        inspected = json.loads(proc.stdout or "")
    except json.JSONDecodeError as exc:
        raise DeployError(f"docker image inspect returned invalid JSON for {ref}") from exc
    if not isinstance(inspected, list) or not inspected or not isinstance(inspected[0], dict):
        raise DeployError(f"docker image inspect returned no image metadata for {ref}")
    return inspected[0]


def container_status(info: dict[str, Any] | None) -> str:
    if not info:
        return "absent"
    return str(info.get("State", {}).get("Status", "unknown"))


def container_health(info: dict[str, Any] | None) -> str:
    if not info:
        return "absent"
    return str(info.get("State", {}).get("Health", {}).get("Status", "none"))


def container_config_image(info: dict[str, Any] | None) -> str | None:
    if not info:
        return None
    value = info.get("Config", {}).get("Image")
    return value if isinstance(value, str) and value else None


def is_running_and_healthy(info: dict[str, Any] | None) -> bool:
    return container_status(info) == "running" and container_health(info) == "healthy"


def digest_from_ref(ref: str | None) -> str | None:
    if not ref or "@sha256:" not in ref:
        return None
    digest = ref.rsplit("@", 1)[1]
    return digest if DIGEST_RE.fullmatch(digest) else None


def port_key(port: PortConfig) -> tuple[str | None, int, str]:
    return (port.host_ip, port.host_port, port.protocol)


def format_port(port: PortConfig) -> str:
    prefix = f"{port.host_ip}:" if port.host_ip else ""
    return f"{prefix}{port.host_port}:{port.container_port}/{port.protocol}"


def docker_publish_spec(port: PortConfig) -> str:
    return format_port(port)


def image_declared_ports(ref: str) -> list[PortConfig]:
    image = inspect_image(ref)
    labels = image.get("Config", {}).get("Labels") or {}
    if not isinstance(labels, dict):
        return []
    raw_ports = labels.get(IMAGE_PUBLISHED_PORTS_LABEL)
    if raw_ports is None or raw_ports == "":
        return []
    if not isinstance(raw_ports, str):
        raise DeployError(f"image label {IMAGE_PUBLISHED_PORTS_LABEL} must be a JSON string")
    try:
        parsed = json.loads(raw_ports)
    except json.JSONDecodeError as exc:
        raise DeployError(
            f"image label {IMAGE_PUBLISHED_PORTS_LABEL} must be a JSON array of port mappings"
        ) from exc
    ports = _parse_port_configs(parsed, f"image label {IMAGE_PUBLISHED_PORTS_LABEL}")
    if ports:
        log(
            f"image declares host-published ports via {IMAGE_PUBLISHED_PORTS_LABEL}: "
            + ", ".join(format_port(port) for port in ports)
        )
    return ports


def effective_published_ports(config: Config, image_ports: list[PortConfig]) -> list[PortConfig]:
    sources = [
        (
            "desktop.host_port",
            [
                PortConfig(
                    host_port=config.desktop.host_port,
                    container_port=config.desktop.container_port,
                    protocol="tcp",
                    description="RustDesk hardened fork Direct IP",
                )
            ],
        ),
        ("desktop.extra_ports", config.desktop.extra_ports),
        (f"image label {IMAGE_PUBLISHED_PORTS_LABEL}", image_ports),
    ]
    ports: list[PortConfig] = []
    seen: dict[tuple[str | None, int, str], tuple[PortConfig, str]] = {}
    for source, source_ports in sources:
        for port in source_ports:
            key = port_key(port)
            previous = seen.get(key)
            if previous:
                previous_port, previous_source = previous
                if previous_port.container_port != port.container_port:
                    raise DeployError(
                        f"host port mapping {format_port(port)} from {source} conflicts with "
                        f"{format_port(previous_port)} from {previous_source}"
                    )
                continue
            seen[key] = (port, source)
            ports.append(port)
    return ports


def remove_container_if_present(name: str) -> None:
    info = inspect_container(name)
    if not info:
        return
    status = container_status(info)
    if status in ("running", "restarting"):
        log(f"stopping existing container {name}")
        run(["docker", "stop", "--time", "30", name], check=False)
    log(f"removing existing container {name}")
    run(["docker", "rm", "-f", name])


def run_container(
    config: Config,
    ref: str,
    *,
    digest: str | None,
    published_ports: list[PortConfig],
) -> None:
    config.desktop.home_dir.mkdir(parents=True, exist_ok=True)
    labels = {
        "haggai.managed": "true",
        "haggai.desktop": config.desktop.name,
        "haggai.image": config.desktop.image,
        "haggai.image_ref": ref,
    }
    if digest:
        labels["haggai.digest"] = digest

    args = [
        "docker",
        "run",
        "-d",
        "--pull",
        "never",
        "--name",
        config.desktop.container_name,
        "--hostname",
        config.desktop.hostname,
        "--restart",
        "unless-stopped",
        "-v",
        f"{config.desktop.home_dir}:/home/user",
        "--cpus",
        config.runtime.cpus,
        "--memory",
        config.runtime.memory,
        "--memory-swap",
        config.runtime.memory_swap,
        "--pids-limit",
        str(config.runtime.pids_limit),
        "--shm-size",
        config.runtime.shm_size,
        "--init",
        "--health-cmd",
        f"ss -ltn | grep -q ':{config.desktop.container_port} '",
        "--health-interval",
        "10s",
        "--health-timeout",
        "5s",
        "--health-retries",
        "12",
        "--health-start-period",
        "90s",
    ]
    for port in published_ports:
        args.extend(["-p", docker_publish_spec(port)])
    for key, value in labels.items():
        args.extend(["--label", f"{key}={value}"])
    args.append(ref)

    log(f"starting {config.desktop.container_name} from {ref}")
    log("publishing ports: " + ", ".join(format_port(port) for port in published_ports))
    proc = run(args, capture=True)
    container_id = (proc.stdout or "").strip()
    if container_id:
        log(f"started container {container_id[:12]}")


def docker_logs_tail(name: str) -> str:
    proc = subprocess.run(
        ["docker", "logs", "--tail", "120", name],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return proc.stdout or ""


def wait_for_health(config: Config) -> None:
    deadline = time.monotonic() + config.runtime.health_timeout_seconds
    while time.monotonic() < deadline:
        info = inspect_container(config.desktop.container_name)
        status = container_status(info)
        health = container_health(info)
        if status == "running" and health == "healthy":
            log("container is healthy")
            return
        if status not in ("running", "created"):
            logs = docker_logs_tail(config.desktop.container_name)
            raise DeployError(
                f"container is {status}, not running while waiting for health\n{logs}"
            )
        if health == "unhealthy":
            logs = docker_logs_tail(config.desktop.container_name)
            raise DeployError(f"container became unhealthy\n{logs}")
        time.sleep(3)
    logs = docker_logs_tail(config.desktop.container_name)
    raise DeployError(
        f"timed out after {config.runtime.health_timeout_seconds}s waiting for health\n{logs}"
    )


def assert_container_running(config: Config) -> None:
    info = inspect_container(config.desktop.container_name)
    status = container_status(info)
    if status != "running":
        logs = docker_logs_tail(config.desktop.container_name)
        raise DeployError(f"container is {status}, expected running\n{logs}")


def clear_rustdesk_password_line(config: Config) -> None:
    rd_toml = config.desktop.home_dir / ".config/rustdesk/RustDesk.toml"
    if not rd_toml.exists():
        return
    text = rd_toml.read_text(encoding="utf-8", errors="replace").splitlines(
        keepends=True
    )
    filtered = [line for line in text if not line.startswith("password = ")]
    if len(filtered) == len(text):
        return
    log("clearing carried-over RustDesk password before reprovisioning")
    tmp = rd_toml.with_name(f"{rd_toml.name}.tmp")
    tmp.write_text("".join(filtered), encoding="utf-8")
    os.replace(tmp, rd_toml)


def provision_passwords(config: Config) -> None:
    password = read_password(config.desktop.password_file)
    home = config.desktop.home_dir
    rd_toml = home / ".config/rustdesk/RustDesk.toml"
    linux_mark = home / ".haggai_linux_pw_ok"
    linux_log = home / ".haggai_linux_pw.log"
    for path in (linux_mark, linux_log):
        try:
            path.unlink()
        except FileNotFoundError:
            pass

    clear_rustdesk_password_line(config)
    env = os.environ.copy()
    env["RD_PASSWORD"] = password

    log("setting the RustDesk permanent password")
    rd_ok = False
    deadline = time.monotonic() + RUSTDESK_PASSWORD_TIMEOUT
    last_fire = 0.0
    while time.monotonic() < deadline:
        assert_container_running(config)
        if time.monotonic() - last_fire >= RUSTDESK_PASSWORD_REFIRE:
            run(
                [
                    "docker",
                    "exec",
                    "-d",
                    "-u",
                    "user",
                    "-e",
                    "RD_PASSWORD",
                    "-e",
                    "DISPLAY=:99",
                    config.desktop.container_name,
                    "bash",
                    "-c",
                    'rustdesk --password "$RD_PASSWORD"',
                ],
                env=env,
            )
            last_fire = time.monotonic()
        time.sleep(POLL_SLEEP)
        if rd_toml.exists():
            content = rd_toml.read_text(encoding="utf-8", errors="replace")
            if re.search(r"^password = '.+'", content, flags=re.MULTILINE):
                rd_ok = True
                break
    if not rd_ok:
        logs = docker_logs_tail(config.desktop.container_name)
        raise DeployError(
            f"RustDesk password was not persisted within {RUSTDESK_PASSWORD_TIMEOUT}s\n{logs}"
        )
    run(
        [
            "docker",
            "exec",
            "-d",
            "-u",
            "user",
            config.desktop.container_name,
            "pkill",
            "-f",
            "rustdesk --password",
        ],
        check=False,
    )
    log("RustDesk password set")

    log("setting the user Linux/sudo password")
    run(
        [
            "docker",
            "exec",
            "-d",
            "-u",
            "0",
            "-e",
            "RD_PASSWORD",
            config.desktop.container_name,
            "bash",
            "-c",
            """
{ printf "user:%s\\n" "$RD_PASSWORD" | chpasswd ; } 2>/home/user/.haggai_linux_pw.log
crc=$?
st="$(passwd -S user 2>>/home/user/.haggai_linux_pw.log | awk "{print \\$2}")"
echo "chpasswd_rc=$crc passwd_status=$st" >>/home/user/.haggai_linux_pw.log
[ "$crc" = 0 ] && [ "$st" = P ] && : >/home/user/.haggai_linux_pw_ok
""".strip(),
        ],
        env=env,
    )
    linux_ok = False
    deadline = time.monotonic() + LINUX_PASSWORD_TIMEOUT
    while time.monotonic() < deadline:
        if linux_mark.exists():
            linux_ok = True
            break
        assert_container_running(config)
        time.sleep(1)
    if not linux_ok:
        diagnostics = ""
        if linux_log.exists():
            diagnostics = linux_log.read_text(encoding="utf-8", errors="replace")
        logs = docker_logs_tail(config.desktop.container_name)
        raise DeployError(
            f"Linux/sudo password was not confirmed within {LINUX_PASSWORD_TIMEOUT}s\n"
            f"{diagnostics}\n{logs}"
        )
    log("Linux/sudo password set")


def _ss_has_listener(output: str, port: PortConfig) -> bool:
    needle = f":{port.host_port}"
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[3].endswith(needle):
            return True
    return False


def assert_host_ports_listening(ports: list[PortConfig]) -> None:
    missing: list[PortConfig] = []
    for protocol, command in (("tcp", ["ss", "-ltn"]), ("udp", ["ss", "-lun"])):
        protocol_ports = [port for port in ports if port.protocol == protocol]
        if not protocol_ports:
            continue
        proc = run(command, capture=True)
        output = proc.stdout or ""
        missing.extend(port for port in protocol_ports if not _ss_has_listener(output, port))
    if missing:
        raise DeployError(
            "host ports are not listening: " + ", ".join(format_port(port) for port in missing)
        )
    log("host ports are listening: " + ", ".join(format_port(port) for port in ports))


def deploy_digest(config: Config, digest: str) -> dict[str, Any]:
    assert_host_preconditions()
    ref = image_ref(config, digest)

    current = inspect_container(config.desktop.container_name)
    current_ref = container_config_image(current)
    if is_running_and_healthy(current) and current_ref == ref:
        try:
            image_ports = image_declared_ports(ref)
            published_ports = effective_published_ports(config, image_ports)
            assert_host_ports_listening(published_ports)
        except DeployError as exc:
            log(
                f"{config.desktop.container_name} is running {ref}, but the host ports are "
                f"not verifiably correct ({exc}); recreating it"
            )
        else:
            log(f"{config.desktop.container_name} is already running {ref}")
            return {"changed": False, "image": config.desktop.image, "digest": digest}

    docker_login_and_pull(config, ref)
    image_ports = image_declared_ports(ref)
    published_ports = effective_published_ports(config, image_ports)

    previous_ref = current_ref
    previous_digest = digest_from_ref(previous_ref)
    if previous_ref:
        log(f"previous image reference is {previous_ref}")

    remove_container_if_present(config.desktop.container_name)
    try:
        run_container(config, ref, digest=digest, published_ports=published_ports)
        provision_passwords(config)
        wait_for_health(config)
        assert_host_ports_listening(published_ports)
    except Exception as exc:
        log(f"deployment of {ref} failed: {exc}")
        remove_container_if_present(config.desktop.container_name)
        if previous_ref:
            log(f"rolling back to {previous_ref}")
            try:
                previous_ports = effective_published_ports(config, image_declared_ports(previous_ref))
                run_container(
                    config,
                    previous_ref,
                    digest=previous_digest,
                    published_ports=previous_ports,
                )
                provision_passwords(config)
                wait_for_health(config)
                assert_host_ports_listening(previous_ports)
            except Exception as rollback_exc:
                raise DeployError(
                    f"deployment failed and rollback to {previous_ref} also failed: "
                    f"{rollback_exc}"
                ) from rollback_exc
            raise DeployError(
                f"deployment failed; rolled back to {previous_ref}: {exc}"
            ) from exc
        raise DeployError(f"deployment failed with no previous container to roll back to: {exc}") from exc

    log(f"deployed {ref}")
    return {"changed": True, "image": config.desktop.image, "digest": digest}


def verify_webhook_signature(config: Config, headers: http.client.HTTPMessage, body: bytes) -> None:
    timestamp = headers.get("X-Haggai-Timestamp", "")
    signature = headers.get("X-Haggai-Signature", "")
    if not timestamp or not signature:
        raise DeployError("missing webhook signature headers")
    if not signature.startswith("sha256="):
        raise DeployError("invalid webhook signature scheme")
    try:
        ts = int(timestamp)
    except ValueError as exc:
        raise DeployError("invalid webhook timestamp") from exc
    now = int(time.time())
    if abs(now - ts) > config.server.signature_tolerance_seconds:
        raise DeployError("webhook timestamp outside tolerance")

    secret = read_secret(config.webhook.secret_file, "webhook secret", min_len=16)
    signed = timestamp.encode("utf-8") + b"." + body
    expected = hmac.new(secret.encode("utf-8"), signed, hashlib.sha256).hexdigest()
    received = signature.removeprefix("sha256=")
    if not hmac.compare_digest(expected, received):
        raise DeployError("invalid webhook signature")


def validate_payload(config: Config, body: bytes) -> str:
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise DeployError("request body must be UTF-8 JSON") from exc
    if not isinstance(payload, dict):
        raise DeployError("request body must be a JSON object")
    if payload.get("desktop") != config.desktop.name:
        raise DeployError("payload desktop does not match configured desktop")
    if payload.get("image") != config.desktop.image:
        raise DeployError("payload image does not match configured image")
    digest = payload.get("digest")
    if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
        raise DeployError("payload digest must be sha256:<64 lowercase hex chars>")
    return digest


def make_handler(config: Config, deploy_lock: threading.Lock) -> type[http.server.BaseHTTPRequestHandler]:
    class DeployHandler(http.server.BaseHTTPRequestHandler):
        server_version = "HaggaiImageWebhook/1.0"

        def do_POST(self) -> None:
            if self.path != "/deploy":
                self.send_json(404, {"ok": False, "error": "not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.send_json(400, {"ok": False, "error": "invalid content length"})
                return
            if length <= 0 or length > config.server.max_body_bytes:
                self.send_json(413, {"ok": False, "error": "request body too large"})
                return
            body = self.rfile.read(length)

            try:
                verify_webhook_signature(config, self.headers, body)
            except DeployError:
                self.send_json(401, {"ok": False, "error": "unauthorized"})
                return

            try:
                digest = validate_payload(config, body)
            except DeployError as exc:
                self.send_json(400, {"ok": False, "error": str(exc)})
                return

            if not deploy_lock.acquire(blocking=False):
                self.send_json(409, {"ok": False, "error": "deployment already in progress"})
                return
            try:
                result = deploy_digest(config, digest)
            except DeployError as exc:
                self.send_json(500, {"ok": False, "error": str(exc)})
                return
            finally:
                deploy_lock.release()
            self.send_json(200, {"ok": True, **result})

        def do_GET(self) -> None:
            self.send_json(404, {"ok": False, "error": "not found"})

        def send_json(self, status: int, payload: dict[str, Any]) -> None:
            encoded = json.dumps(payload, sort_keys=True).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, fmt: str, *args: Any) -> None:
            log(f"{self.address_string()} - {fmt % args}")

    return DeployHandler


def serve(config: Config) -> None:
    assert_host_preconditions()
    handler = make_handler(config, threading.Lock())
    address = (config.server.listen_host, config.server.listen_port)
    server = http.server.ThreadingHTTPServer(address, handler)
    log(f"listening on http://{config.server.listen_host}:{config.server.listen_port}/deploy")
    server.serve_forever()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Haggai immutable image webhook")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("/etc/haggai/deployer.toml"),
        help="path to deployer TOML config",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("serve", help="run the authenticated webhook server")

    deploy_parser = subparsers.add_parser("deploy", help="deploy one digest manually")
    deploy_parser.add_argument("--digest", required=True, help="sha256:<64 lowercase hex chars>")
    deploy_parser.add_argument(
        "--image",
        help="optional safety check; must equal desktop.image from the config",
    )

    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
        if args.command == "serve":
            serve(config)
        elif args.command == "deploy":
            if args.image and args.image != config.desktop.image:
                raise DeployError("--image does not match desktop.image from the config")
            result = deploy_digest(config, args.digest)
            print(json.dumps({"ok": True, **result}, sort_keys=True))
        else:  # pragma: no cover - argparse prevents this.
            raise DeployError(f"unknown command: {args.command}")
    except KeyboardInterrupt:
        return 130
    except DeployError as exc:
        print(f"fatal: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
