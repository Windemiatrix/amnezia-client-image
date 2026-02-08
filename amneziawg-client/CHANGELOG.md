# Changelog

## 1.1.0

- **Gateway mode**: the add-on now uses host networking (`host_network: true`) and can serve as a VPN gateway for other devices on the LAN.
- Added FORWARD chain iptables rules for routing LAN traffic through the VPN tunnel.
- Kill switch now manages FORWARD chain (allows VPN-only forwarding, drops the rest).
- Updated documentation with gateway setup instructions.

## 1.0.0

- Initial release of AmneziaWG Client add-on.
- Userspace AmneziaWG VPN client (no kernel module required).
- Kill switch support for traffic leak prevention.
- Health check with periodic VPN connectivity verification.
- Multi-architecture support: amd64, aarch64, armv7, armhf.
- Configurable logging level, health check host, and kill switch.
