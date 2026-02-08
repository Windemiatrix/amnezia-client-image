# AmneziaWG Client — Home Assistant Add-on

## Overview

This add-on runs an [AmneziaWG](https://amnezia.org/) VPN client inside Home Assistant using a userspace Go implementation. No kernel module required — it works on any system that supports Docker (including Raspberry Pi).

AmneziaWG is a WireGuard-based VPN protocol with additional traffic obfuscation to resist DPI blocking.

## Installation

1. Open **Home Assistant** → **Settings** → **Add-ons** → **Add-on Store**.
2. Click the **⋮** menu (top right) → **Repositories**.
3. Add the repository URL:
   ```
   https://github.com/Windemiatrix/amnedia-client-image
   ```
4. Find **AmneziaWG Client** in the store and click **Install**.

## Configuration

### Config File

Place your AmneziaWG `.conf` file in the Home Assistant `/config` directory (e.g., `/config/wg0.conf`).

The config file uses the standard WireGuard format with additional AmneziaWG obfuscation parameters (`Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1`–`H4`):

```ini
[Interface]
Address = 100.75.XXX.XXX/32
DNS = 8.8.8.8, 8.8.4.4
PrivateKey = <your-private-key>
Jc = 2
Jmin = 10
Jmax = 50
S1 = 26
S2 = 85
H1 = 587828137
H2 = 180295271
H3 = 1960955419
H4 = 1361134988

[Peer]
PublicKey = <server-public-key>
PresharedKey = <preshared-key>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = <server-ip>:31793
PersistentKeepalive = 25
```

> **Security**: Never share your `.conf` file — it contains your private key, preshared key, and server endpoint. The example above has all sensitive values replaced with placeholders.

### Options

| Option              | Default    | Description                                            |
| ------------------- | ---------- | ------------------------------------------------------ |
| `config_file`       | `wg0.conf` | Name of the config file in `/config`                   |
| `log_level`         | `info`     | Logging verbosity: `debug`, `info`, `warn`, `error`    |
| `health_check_host` | `1.1.1.1`  | IP address to ping through VPN for health verification |
| `kill_switch`       | `true`     | Block all traffic if VPN tunnel goes down              |

### Example Configuration

```yaml
config_file: "wg0.conf"
log_level: "info"
health_check_host: "1.1.1.1"
kill_switch: true
```

## How It Works

1. The add-on reads the AmneziaWG config from `/config/<config_file>`.
2. A TUN interface is created and the VPN tunnel is established using `awg-quick up`.
3. NAT (MASQUERADE) rules are applied for traffic forwarding.
4. If **kill switch** is enabled, iptables rules block all non-VPN traffic.
5. A health check periodically pings `health_check_host` through the VPN tunnel.

## Kill Switch

When enabled (default), the kill switch blocks all network traffic that doesn't go through the VPN tunnel. This prevents data leaks if the VPN connection drops.

The kill switch allows:
- Traffic to the VPN endpoint (so the tunnel can reconnect)
- Loopback traffic
- DNS traffic to servers specified in the config
- Established/related connections

## Health Check

The add-on performs periodic health checks (every 60 seconds):

1. Verifies the VPN interface exists.
2. Checks for a recent WireGuard handshake.
3. Pings the configured `health_check_host` through the VPN interface.

If any check fails, the add-on is marked as **unhealthy**.

## Troubleshooting

### VPN doesn't connect

- Verify your `.conf` file is valid and placed in `/config`.
- Check the add-on logs for error messages.
- Ensure the VPN server is reachable from your network.
- Try setting `log_level` to `debug` for more details.

### Add-on shows unhealthy

- The VPN tunnel may have lost connection — check the logs.
- Verify the `health_check_host` is reachable through the VPN.
- Try restarting the add-on.

### Traffic doesn't route through VPN

- Make sure `kill_switch` is enabled to prevent leaks.
- Verify the server config has `AllowedIPs = 0.0.0.0/0` for full tunnel mode.

## Support

- [GitHub Issues](https://github.com/Windemiatrix/amnedia-client-image/issues)
- [AmneziaWG Documentation](https://docs.amnezia.org/)
