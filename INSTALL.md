# Yapper Server — Manual Installation

> Requires: root access, a systemd-based Linux (Debian/Ubuntu, RHEL/Rocky/Fedora, or Arch), `x86_64` or `aarch64`, and `curl` + `tar` installed.

All commands below are run as **root** (use `sudo -i` or prefix with `sudo`).

Prefer the automated path? See [`install.sh`](./install.sh). The steps below do exactly the same thing, just by hand.

---

## 1. Install prerequisites

**Debian / Ubuntu:**
```bash
apt-get update
apt-get install -y curl tar ca-certificates libc6 libstdc++6
```

**RHEL / Rocky / Fedora:**
```bash
dnf install -y curl tar ca-certificates glibc libstdc++
```

**Arch:**
```bash
pacman -Sy --noconfirm curl tar ca-certificates glibc gcc-libs
```

---

## 2. Pick your ports and check they are free

Yapper needs **two TCP ports**: a listen port (default `7880`) and an RTC port (listen + 1, so `7881`).
It also uses **UDP `50000–60000`** for media.

Check the TCP ports are not already in use:
```bash
ss -ltnp | grep -E ':(7880|7881)\b'
```
If anything shows up, pick different ports or stop the conflicting service.

---

## 3. Download the latest release

Detect your architecture:
```bash
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
esac
```

Get the latest version and download:
```bash
VERSION=$(curl -fsSL https://api.github.com/repos/kardebadas/yapper/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')

cd /tmp
curl -fSLO "https://github.com/kardebadas/yapper/releases/download/v${VERSION}/yapper_${VERSION}_linux_${ARCH}.tar.gz"
curl -fSLO "https://github.com/kardebadas/yapper/releases/download/v${VERSION}/checksums.txt"
```

Verify the checksum (recommended):
```bash
sha256sum -c --ignore-missing checksums.txt
```

Extract and install the binary:
```bash
install -d -m 755 /opt/yapper-server
tar xzf "yapper_${VERSION}_linux_${ARCH}.tar.gz"
mv yapper-server /opt/yapper-server/yapper-server
chown root:root /opt/yapper-server/yapper-server
chmod 755 /opt/yapper-server/yapper-server
```

---

## 4. Create the service user

```bash
groupadd --system yapper
useradd  --system --gid yapper --no-create-home --shell /usr/sbin/nologin yapper
chown yapper:yapper /opt/yapper-server
```

---

## 5. Write the server config

Replace `7880` / `7881` if you chose different ports.

```bash
cat > /opt/yapper-server/config.yaml <<'YAML'
port: 7880

rtc:
  use_external_ip: false
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  packet_buffer_size_audio: 200

logging:
  level: info

room:
  enabled_codecs:
    - mime: audio/opus
    - mime: audio/red
    - mime: video/vp8
    - mime: video/vp9
    - mime: video/h264
    - mime: video/av1

audio:
  active_level: 40
  active_red_encoding: true
YAML

chown yapper:yapper /opt/yapper-server/config.yaml
chmod 644 /opt/yapper-server/config.yaml
```

---

## 6. Install your license

Create the data directory and drop your license file in. The license **must contain** `license_key=`, `instance_domain=`, and `instance_port=`.

```bash
install -d -m 755 -o yapper -g yapper /opt/yapper-server/audio-server-data

# Paste your license here:
cat > /opt/yapper-server/audio-server-data/license.txt <<'LICENSE'
license_key=YOUR_LICENSE_KEY_HERE
instance_domain=chat.example.com
instance_port=7880
# ...any other lines from the license you were given
LICENSE

chown yapper:yapper /opt/yapper-server/audio-server-data/license.txt
chmod 600 /opt/yapper-server/audio-server-data/license.txt
```

> `instance_port` is the **public** port your users will connect to (often `443` if you put Caddy/Nginx in front).
> `port:` in `config.yaml` is the **local** port the binary binds to.

---

## 7. Install the systemd service

```bash
cat > /etc/systemd/system/yapper-server.service <<'EOF'
[Unit]
Description=Yapper Server
After=network-online.target
Wants=network-online.target

[Service]
User=yapper
Group=yapper
WorkingDirectory=/opt/yapper-server
ExecStart=/opt/yapper-server/yapper-server --config /opt/yapper-server/config.yaml
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now yapper-server
```

Check it is running:
```bash
systemctl status yapper-server
journalctl -u yapper-server -n 30 --no-pager
```

---

## 8. (Optional) Reverse proxy with Caddy

Skip this whole section if you already use Nginx/HAProxy/etc.

Install Caddy:

**Debian/Ubuntu:**
```bash
apt-get install -y gnupg ca-certificates debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy
```

**RHEL/Rocky/Fedora:**
```bash
dnf install -y 'dnf-command(copr)'
dnf copr enable -y @caddy/caddy
dnf install -y caddy
```

**Arch:**
```bash
pacman -Sy --noconfirm caddy
```

**With automatic HTTPS (Let's Encrypt — requires ports 80 + 443 free and DNS pointing at this server):**
```bash
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<'EOF'
chat.example.com {
    reverse_proxy localhost:7880
}
EOF
```

**HTTP only (no SSL — requires port 80 free):**
```bash
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<'EOF'
{
    auto_https off
}

http://chat.example.com {
    reverse_proxy localhost:7880
}
EOF
```

Validate and start:
```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl status caddy
```

---

## 9. (Optional) Automatic updates every 24 hours

Install the update helper:
```bash
cat > /usr/local/sbin/yapper-update <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BINARY_PATH=/opt/yapper-server/yapper-server
DATA_DIR=/opt/yapper-server/audio-server-data
LICENSE_FILE=/opt/yapper-server/audio-server-data/license.txt
SERVICE_NAME=yapper-server

before_version="$("${BINARY_PATH}" --version 2>/dev/null || true)"
[[ -n "${before_version}" ]] || { echo "Cannot read current version" >&2; exit 1; }

"${BINARY_PATH}" update --yes --data-dir "${DATA_DIR}" --license-file "${LICENSE_FILE}"

after_version="$("${BINARY_PATH}" --version 2>/dev/null || true)"
[[ -n "${after_version}" ]] || { echo "Cannot read updated version" >&2; exit 1; }

if [[ "${after_version}" != "${before_version}" ]]; then
    echo "Updated: ${before_version} -> ${after_version}"
    systemctl restart "${SERVICE_NAME}"
fi
EOF
chmod 755 /usr/local/sbin/yapper-update
```

Service + timer:
```bash
cat > /etc/systemd/system/yapper-update.service <<'EOF'
[Unit]
Description=Yapper update check and apply
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=/opt/yapper-server
ExecStart=/usr/local/sbin/yapper-update
EOF

cat > /etc/systemd/system/yapper-update.timer <<'EOF'
[Unit]
Description=Run Yapper auto-update

[Timer]
OnBootSec=10m
OnUnitActiveSec=24h
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now yapper-update.timer
```

---

## 10. Firewall (open these ports)

| Port              | Protocol | Purpose                           |
|-------------------|----------|-----------------------------------|
| `7880` (or chosen)| TCP      | Yapper listen (or `443` via Caddy)|
| `7881`            | TCP      | Yapper RTC                        |
| `50000–60000`     | UDP      | Media (WebRTC)                    |
| `80`, `443`       | TCP      | Only if using Caddy / HTTPS       |

---

## Useful commands

```bash
systemctl status yapper-server
systemctl restart yapper-server
journalctl -u yapper-server -f

# Auto-update (if installed):
systemctl status yapper-update.timer
journalctl -u yapper-update.service -f
```

---

## Uninstall

```bash
systemctl disable --now yapper-server
systemctl disable --now yapper-update.timer 2>/dev/null || true

rm -f /etc/systemd/system/yapper-server.service
rm -f /etc/systemd/system/yapper-update.service
rm -f /etc/systemd/system/yapper-update.timer
rm -f /usr/local/sbin/yapper-update
systemctl daemon-reload

rm -rf /opt/yapper-server

userdel  yapper 2>/dev/null || true
groupdel yapper 2>/dev/null || true
```
