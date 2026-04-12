<div align="center">
<pre>
<span style="color:#ff4d6d;">██╗   ██╗</span> <span style="color:#ff6b6b;">█████╗</span> <span style="color:#f7b801;">██████╗</span> <span style="color:#ffd166;">██████╗</span> <span style="color:#06d6a0;">███████╗</span><span style="color:#00d1b2;">██████╗</span>   <span style="color:#4cc9f0;"> ██████╗</span><span style="color:#4895ef;">██╗  ██╗</span><span style="color:#4361ee;"> █████╗</span><span style="color:#3a0ca3;">████████╗</span>
<span style="color:#ff4d6d;">╚██╗ ██╔╝</span><span style="color:#ff6b6b;">██╔══██╗</span><span style="color:#f7b801;">██╔══██╗</span><span style="color:#ffd166;">██╔══██╗</span><span style="color:#06d6a0;">██╔════╝</span><span style="color:#00d1b2;">██╔══██╗</span>  <span style="color:#4cc9f0;">██╔════╝</span><span style="color:#4895ef;">██║  ██║</span><span style="color:#4361ee;">██╔══██╗</span><span style="color:#3a0ca3;">╚══██╔══╝</span>
<span style="color:#ff4d6d;"> ╚████╔╝ </span><span style="color:#ff6b6b;">███████║</span><span style="color:#f7b801;">██████╔╝</span><span style="color:#ffd166;">██████╔╝</span><span style="color:#06d6a0;">█████╗  </span><span style="color:#00d1b2;">██████╔╝</span>  <span style="color:#4cc9f0;">██║     </span><span style="color:#4895ef;">███████║</span><span style="color:#4361ee;">███████║</span><span style="color:#3a0ca3;">   ██║   </span>
<span style="color:#ff4d6d;">  ╚██╔╝  </span><span style="color:#ff6b6b;">██╔══██║</span><span style="color:#f7b801;">██╔═══╝ </span><span style="color:#ffd166;">██╔═══╝ </span><span style="color:#06d6a0;">██╔══╝  </span><span style="color:#00d1b2;">██╔══██╗</span>  <span style="color:#4cc9f0;">██║     </span><span style="color:#4895ef;">██╔══██║</span><span style="color:#4361ee;">██╔══██║</span><span style="color:#3a0ca3;">   ██║   </span>
<span style="color:#ff4d6d;">   ██║   </span><span style="color:#ff6b6b;">██║  ██║</span><span style="color:#f7b801;">██║     </span><span style="color:#ffd166;">██║     </span><span style="color:#06d6a0;">███████╗</span><span style="color:#00d1b2;">██║  ██║</span>  <span style="color:#4cc9f0;">╚██████╗</span><span style="color:#4895ef;">██║  ██║</span><span style="color:#4361ee;">██║  ██║</span><span style="color:#3a0ca3;">   ██║   </span>
<span style="color:#ff4d6d;">   ╚═╝   </span><span style="color:#ff6b6b;">╚═╝  ╚═╝</span><span style="color:#f7b801;">╚═╝     </span><span style="color:#ffd166;">╚═╝     </span><span style="color:#06d6a0;">╚══════╝</span><span style="color:#00d1b2;">╚═╝  ╚═╝</span>  <span style="color:#4cc9f0;"> ╚═════╝</span><span style="color:#4895ef;">╚═╝  ╚═╝</span><span style="color:#4361ee;">╚═╝  ╚═╝</span><span style="color:#3a0ca3;">   ╚═╝   </span>
</pre>

</div>

Self-hosted spatial voice, chat, and screen sharing for private communities.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/kardebadas/yapper/main/install.sh | bash
```

## What is Yapper?

**Yapper** is a self-hosted, real-time communication platform where **you control the entire backend**  voice, chat, files, and media all run on infrastructure you own.

Clients connect directly to your server, which handles all communication in real time.

---

## Features

- Spatial voice rooms with proximity-based audio
- Screen sharing with audio
- Encrypted messaging (room + proximity chat)
- Voice channels with granular permissions
- Friend system with real-time presence
- Role-based access control

---

## Architecture

- The **server is the source of truth** it manages voice, chat, file transfer, and media streams
- Clients connect **directly to your server**, not through third-party relays
- No external services required for core communication

---

## Philosophy

> Your server. Your data. Your rules.

## Requirements

- Linux server (x86_64 or arm64)
- A valid license key from [yapper.gg](https://yapper.gg)

## Manual Install

1. Download the latest release from the [Releases](https://github.com/kardebadas/yapper/releases) page
2. Download your license from [Licenses](https://yapper.gg/licenses)
3. Set up the folder structure and run:

```bash
tar xzf yapper_*_linux_amd64.tar.gz
mkdir -p audio-server-data
# Copy the default config from this repository or the release bundle
# Redis is optional and stays commented out by default
# Save your license file as audio-server-data/license.txt
chmod +x yapper-server
./yapper-server --config config.yaml
```

Default `config.yaml`:

```yaml
port: 7880

rtc:
  use_external_ip: false
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  packet_buffer_size_audio: 200
  # interfaces:
  #   includes:
  #     - en0
  #   excludes:
  #     - docker0
  # # ip address filter. If the machine has more than one ip address and you'd like it to use or skip specific ips,
  # # both inclusion and exclusion CIDR filters can be used together. If neither is defined (default), all ip on the machine will be used.
  # # If both of them are set, then only include takes effect.
  # ips:
  #   includes:
  #     - 10.0.0.0/16
  #   excludes:
  #     - 10.10.10.0/16

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
```

Folder structure:

```
yapper-server/
├── yapper-server           # binary
├── config.yaml             # server configuration
└── audio-server-data/
    └── license.txt         # license from yapper.gg
```

## License

The server binary and clients are proprietary software — see [LICENSE](LICENSE).

Install scripts are MIT licensed.

## Links

- [Website](https://yapper.gg)
- [Pricing](https://yapper.gg/pricing)
- [Downloads](https://yapper.gg/downloads)
- [Roadmap](https://yapper.gg/roadmap)
