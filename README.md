# amnezia-client-image

[![Build](https://github.com/Windemiatrix/amnezia-client-image/actions/workflows/build.yml/badge.svg)](https://github.com/Windemiatrix/amnezia-client-image/actions/workflows/build.yml)
[![Release](https://github.com/Windemiatrix/amnezia-client-image/actions/workflows/release.yml/badge.svg)](https://github.com/Windemiatrix/amnezia-client-image/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Docker image for the [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go) VPN client running entirely in userspace. Works with Docker, Docker Compose, Kubernetes, and Home Assistant.

The host kernel does **not** need an AmneziaWG module — the Go-based userspace implementation handles everything via a TUN interface.

> **🇷🇺 Русская версия:** [README.ru.md](README.ru.md)

---

## Table of Contents

- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [VPN Gateway Mode](#vpn-gateway-mode)
- [Kubernetes](#kubernetes)
- [Home Assistant Add-on](#home-assistant-add-on)
- [Health Check](#health-check)
- [Kill Switch](#kill-switch)
- [Building from Source](#building-from-source)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Quick Start

```bash
docker run -d \
  --name=amneziawg \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --device=/dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv4.ip_forward=1 \
  -v /path/to/config:/config \
  --restart=unless-stopped \
  ghcr.io/windemiatrix/amnezia-client-image:latest
```

Place your AmneziaWG `.conf` file inside the mounted `/config` directory. The filename determines the network interface name (`wg0.conf` → `wg0`).

---

## Configuration

### Environment Variables

| Variable            | Default            | Description                                                                   |
| ------------------- | ------------------ | ----------------------------------------------------------------------------- |
| `WG_CONFIG_FILE`    | `/config/wg0.conf` | Path to the AmneziaWG configuration file                                      |
| `LOG_LEVEL`         | `info`             | Logging verbosity: `debug`, `info`, `warn`, `error`                           |
| `KILL_SWITCH`       | `1`                | Block traffic outside VPN: `1` — on, `0` — off                                |
| `HEALTH_CHECK_HOST` | `1.1.1.1`          | IP address to ping through VPN for health checks                              |
| `LOCAL_SUBNETS`     | *(empty)*          | Comma-separated CIDRs to exclude from VPN (e.g., `192.168.0.0/16,10.0.0.0/8`) |

### Required Runtime Parameters

| Parameter   | Value                                | Purpose                                      |
| ----------- | ------------------------------------ | -------------------------------------------- |
| `--device`  | `/dev/net/tun:/dev/net/tun`          | TUN device for VPN tunnel                    |
| `--cap-add` | `NET_ADMIN`                          | Network interface and iptables management    |
| `--cap-add` | `SYS_MODULE`                         | Kernel module loading (optional)             |
| `--sysctl`  | `net.ipv4.conf.all.src_valid_mark=1` | Correct routing with fwmark                  |
| `--sysctl`  | `net.ipv4.ip_forward=1`              | Traffic forwarding (needed for gateway mode) |

### Config File Format

The container expects a standard AmneziaWG configuration file (extended WireGuard format with obfuscation parameters). The file must contain `[Interface]` and `[Peer]` sections.

> **Security:** `.conf` files contain private keys. Never commit them to version control.

---

## VPN Gateway Mode

### LAN Gateway (route network devices through VPN)

Use the container as a network gateway so that other devices (PCs, phones, IoT) route traffic through the VPN tunnel. This requires **host networking** so the container shares the host's IP address.

```bash
docker run -d \
  --name=amneziawg-gw \
  --network=host \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --device=/dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv4.ip_forward=1 \
  -v /path/to/config:/config \
  -e KILL_SWITCH=0 \
  --restart=unless-stopped \
  ghcr.io/windemiatrix/amnezia-client-image:latest
```

Then on your router, add a static route:

```
Destination: 0.0.0.0/0       # or a specific subnet like 10.0.0.0/8
Gateway:     192.168.1.100   # IP of the host running the container
```

> **Note:** Disable the kill switch (`KILL_SWITCH=0`) in gateway mode — otherwise incoming traffic from LAN will be blocked.

The entrypoint automatically configures iptables FORWARD rules and NAT MASQUERADE on the VPN interface.

### Container Gateway (route other containers through VPN)

Route traffic from other containers through the VPN tunnel using Docker Compose `network_mode: service:vpn`:

```yaml
services:
  vpn:
    image: ghcr.io/windemiatrix/amnezia-client-image:latest
    container_name: amneziawg
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    volumes:
      - ./config:/config
    environment:
      - KILL_SWITCH=1
      - LOG_LEVEL=info
      - HEALTH_CHECK_HOST=1.1.1.1
      - LOCAL_SUBNETS=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12
    restart: unless-stopped

  app:
    image: curlimages/curl:latest
    network_mode: service:vpn
    depends_on:
      vpn:
        condition: service_healthy
    command: ["curl", "-s", "https://ifconfig.me"]
```

The entrypoint automatically configures iptables NAT MASQUERADE on the VPN interface for gateway traffic.

See the full example: [examples/docker-compose.yml](examples/docker-compose.yml)

---

## Kubernetes

Deploy as a sidecar container in a pod. The VPN container shares the network namespace with application containers.

Example manifests are in [examples/kubernetes/](examples/kubernetes/):

- **deployment.yaml** — Deployment with AmneziaWG sidecar
- **configmap.yaml** — ConfigMap template (store private keys in a Secret)

> **Important:** In Kubernetes, use a `Secret` for the `.conf` file since it contains private keys.

---

## Home Assistant Add-on

### Installation

1. Add this repository to Home Assistant: **Settings → Add-ons → Add-on Store → ⋮ → Repositories**

   ```
   https://github.com/Windemiatrix/amnezia-client-image
   ```

2. Find **AmneziaWG Client** in the store and install it.
3. Place your `.conf` file in the Home Assistant `/config` directory.
4. Configure the add-on options:
   - **Config File** — name of the `.conf` file (e.g., `wg0.conf`)
   - **Log Level** — logging verbosity
   - **Health Check Host** — IP to ping through VPN
   - **Kill Switch** — block traffic outside VPN
   - **Local Subnets** — subnets to exclude from VPN routing (keep LAN access)
5. Start the add-on.

See [amneziawg-client/DOCS.md](amneziawg-client/DOCS.md) for detailed documentation.

---

## Health Check

The container includes a built-in health check that runs every 60 seconds:

1. **Interface check** — verifies the VPN interface exists (`ip link show`)
2. **Handshake check** — confirms a recent handshake with the peer (`awg show`)
3. **Connectivity check** — pings `HEALTH_CHECK_HOST` through the VPN interface

If any check fails, the container is marked as `unhealthy`. Orchestrators (Docker, Kubernetes) can use this to restart the container automatically.

```
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3
```

---

## Kill Switch

When `KILL_SWITCH=1` (default), the entrypoint configures iptables rules to prevent traffic leaks if the VPN tunnel drops:

1. Allow loopback traffic
2. Allow traffic to the AmneziaWG endpoint (IP:port parsed from `.conf`)
3. Allow traffic to local subnets (from `LOCAL_SUBNETS`)
4. Allow traffic through the VPN interface
5. Allow ICMPv6 neighbor discovery
6. Allow DNS traffic to servers from `.conf` (if DNS is configured)
7. Allow FORWARD through the VPN interface (gateway mode)
8. Allow established/related connections
9. **DROP** everything else (OUTPUT, INPUT, and FORWARD)

This also provides DNS leak protection — DNS queries are restricted to the VPN tunnel.

To disable the kill switch:

```bash
-e KILL_SWITCH=0
```

---

## Building from Source

### Prerequisites

- Docker with [Buildx](https://docs.docker.com/build/buildx/) enabled
- GNU Make
- [ShellCheck](https://www.shellcheck.net/) (for linting)

### Build Commands

```bash
# Build for the current platform
make build

# Build and run smoke tests
make test

# Run linters (Hadolint + ShellCheck)
make lint

# Build multi-arch image (no load)
make build-multi

# Build and push multi-arch image to GHCR
make push
```

### Development Commands

```bash
# Run container locally (requires .conf in ./config/)
make run

# View container logs
make logs

# Open a shell inside the container
make shell

# Stop and remove container
make stop

# Full cleanup (stop container + remove image)
make clean
```

### Override Build Variables

Copy `.env.example` to `.env` and edit:

```bash
cp .env.example .env
```

| Variable                  | Default                                             | Description                  |
| ------------------------- | --------------------------------------------------- | ---------------------------- |
| `IMAGE_NAME`              | `ghcr.io/windemiatrix/amnezia-client-image`         | Image name                   |
| `IMAGE_TAG`               | `latest`                                            | Image tag                    |
| `PLATFORMS`               | `linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6` | Target platforms             |
| `CONFIG_DIR`              | `./config`                                          | Host path for config files   |
| `AMNEZIAWG_GO_VERSION`    | `v0.2.16`                                           | amneziawg-go upstream tag    |
| `AMNEZIAWG_TOOLS_VERSION` | `v1.0.20250903`                                     | amneziawg-tools upstream tag |

### Supported Architectures

| Platform       | Devices                              |
| -------------- | ------------------------------------ |
| `linux/amd64`  | x86_64 servers, desktops             |
| `linux/arm64`  | Raspberry Pi 4/5, Apple Silicon (VM) |
| `linux/arm/v7` | Raspberry Pi 3, ARM SBCs             |
| `linux/arm/v6` | Raspberry Pi Zero/1                  |

---

## Troubleshooting

### Container exits immediately

Check that you have a valid `.conf` file mounted:

```bash
docker logs amneziawg
```

If you see `Configuration file not found`, verify the mount path and filename.

### Container is unhealthy

```bash
docker exec amneziawg /healthcheck.sh
```

This will print which check failed: interface, handshake, or connectivity.

### No internet inside the VPN container

1. Verify the AmneziaWG server is reachable from the host.
2. Check that `--sysctl net.ipv4.conf.all.src_valid_mark=1` is set.
3. Try disabling the kill switch temporarily: `-e KILL_SWITCH=0`.

### Lost connection to host / Home Assistant after starting VPN

This happens when `AllowedIPs = 0.0.0.0/0` routes all traffic (including local) through the VPN tunnel. Set `LOCAL_SUBNETS` to keep local network traffic off the tunnel:

```bash
-e LOCAL_SUBNETS=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12
```

For Home Assistant, the add-on includes these subnets by default in the `local_subnets` option.

### Traffic from other containers doesn't go through VPN

1. Ensure `net.ipv4.ip_forward=1` sysctl is set.
2. Verify the app container uses `network_mode: service:vpn`.
3. Check that the VPN container is healthy before starting the app.

### DNS resolution fails

1. Ensure your `.conf` file has a `DNS` entry under `[Interface]`.
2. With kill switch enabled, only the DNS servers listed in the config are allowed.

### Permission denied / TUN device errors

Ensure both `--cap-add=NET_ADMIN` and `--device=/dev/net/tun:/dev/net/tun` are set. On some systems, `--cap-add=SYS_MODULE` may also be required.

### Debug logging

Enable verbose output:

```bash
-e LOG_LEVEL=debug
```

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

AmneziaWG is developed by [Amnezia VPN](https://github.com/amnezia-vpn).
