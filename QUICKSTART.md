# Yapper Server — Quick Start

The fast path. For the full step-by-step, see [INSTALL.md](./INSTALL.md).

- **Download the binary** from the [latest release](https://github.com/kardebadas/yapper/releases/latest) — pick `linux_amd64` or `linux_arm64`.
- **Extract & make it executable:**
  ```bash
  tar xzf yapper_*_linux_*.tar.gz
  chmod +x yapper-server
  sudo mkdir -p /opt/yapper-server
  sudo mv yapper-server /opt/yapper-server/yapper-server
  ```
- **Create the config file** at `/opt/yapper-server/config.yaml`:
  ```yaml
  port: 7880
  rtc:
    use_external_ip: false
    tcp_port: 7881
    port_range_start: 50000
    port_range_end: 60000
  logging:
    level: info
  ```
- **Paste your license** into `/opt/yapper-server/audio-server-data/license.txt` (must include `license_key=`, `instance_domain=`, `instance_port=`).
- **Your domain needs SSL** — point `chat.yourdomain.com` at the server's IP and put Caddy / Nginx in front of port `7880` with HTTPS. Yapper will not work without HTTPS.
- **Open the firewall:** TCP `7880`, TCP `7881`, UDP `50000–60000` (plus `80`/`443` for the proxy).
- **Run the binary:**
  ```bash
  /opt/yapper-server/yapper-server --config /opt/yapper-server/config.yaml
  ```
  (or set up the systemd service — see [INSTALL.md](./INSTALL.md) step 7)
- **Test it from yapper.gg** — log in to your account on [yapper.gg](https://yapper.gg), go to **My Servers**, find your instance and join it. That's where the connection is validated, not by opening the domain in a browser.
