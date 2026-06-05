#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  Yapper Server — Automated Installer
#  https://github.com/kardebadas/yapper
# ============================================================================

REPO_OWNER="kardebadas"
REPO_NAME="yapper"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
INSTALL_DIR="/opt/yapper-server"
BINARY_NAME="yapper-server"
CONFIG_FILE="${INSTALL_DIR}/config.yaml"
DATA_DIR="${INSTALL_DIR}/audio-server-data"
LICENSE_FILE="${DATA_DIR}/license.txt"
SERVICE_NAME="yapper-server"
SERVICE_USER="yapper"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
UPDATE_UNIT_NAME="yapper-update"
UPDATE_SCRIPT="/usr/local/sbin/${UPDATE_UNIT_NAME}"
UPDATE_SERVICE_FILE="/etc/systemd/system/${UPDATE_UNIT_NAME}.service"
UPDATE_TIMER_FILE="/etc/systemd/system/${UPDATE_UNIT_NAME}.timer"
TOTAL_STEPS=10
TMP_DIR=""

# Collected during interactive phase
OS_FAMILY=""
PKG_MANAGER=""
ARCH=""
LICENSE_CONTENT=""
LICENSE_KEY=""
INSTANCE_DOMAIN=""
INSTANCE_PORT=""
SERVER_PORT=""
SERVER_RTC_PORT=""
FINAL_LICENSE=""
INSTALL_CADDY=false
CADDY_DOMAIN=""
CADDY_SSL=false
ENABLE_AUTO_UPDATE=false

# ── Colors ──────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# ── Helpers ─────────────────────────────────────────────────────────────────

log_step()  { echo -e "${CYAN}[${1}/${TOTAL_STEPS}]${RESET} ${BOLD}${2}${RESET}"; }
log_ok()    { echo -e "  ${GREEN}✓${RESET} ${1}"; }
log_warn()  { echo -e "  ${YELLOW}⚠${RESET} ${1}"; }
log_fail()  { echo -e "  ${RED}✗${RESET} ${1}"; exit 1; }
log_info()  { echo -e "  ${1}"; }

prompt_yes_no() {
    local question="$1"
    local default="${2:-}"
    local prompt="[y/n]"

    case "${default}" in
        yes) prompt="[Y/n]" ;;
        no)  prompt="[y/N]" ;;
    esac

    while true; do
        read -rp "  ${question} ${prompt}: " yn </dev/tty
        if [[ -z "${yn}" ]]; then
            case "${default}" in
                yes) return 0 ;;
                no)  return 1 ;;
            esac
        fi

        case "${yn}" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

require_free_tcp_port() {
    local port="$1"
    local label="${2:-Port ${port}}"
    local hint="${3:-}"
    local listener_lines=""

    listener_lines=$(ss -ltnp 2>/dev/null | awk -v port="${port}" '$1 == "LISTEN" && $4 ~ ("(^|:)" port "$") {print}')
    if [[ -n "${listener_lines}" ]]; then
        echo ""
        log_warn "${label}: TCP port ${port} is already in use."
        echo ""
        echo -e "  Something on this machine is already listening on ${BOLD}${port}/tcp${RESET}:"
        while IFS= read -r line; do
            [[ -n "${line}" ]] && echo "    ${line}"
        done <<< "${listener_lines}"
        echo ""

        if [[ "${hint}" == "caddy_ssl" ]]; then
            echo -e "  You chose ${BOLD}Caddy with automatic SSL${RESET}. That setup needs:"
            echo "    - port 80/tcp for the ACME HTTP challenge"
            echo "    - port 443/tcp for HTTPS traffic"
            echo ""
            echo "  How to fix it:"
            echo "    1. Stop the service already using this port."
            echo "    2. Or disable the existing web server if you do not need it."
            echo "    3. Or rerun this installer and answer no to Caddy/automatic SSL."
            echo ""
            echo "  Common commands:"
            echo "    sudo ss -ltnp | grep -E '(:80|:443)\\b'"
            echo "    sudo systemctl stop nginx"
            echo "    sudo systemctl stop apache2"
            echo "    sudo systemctl stop httpd"
            echo ""
            log_fail "Cannot continue until ports 80 and 443 are free for Caddy."
        fi

        echo "  Free the port and run the installer again."
        echo ""
        log_fail "Cannot continue while TCP port ${port} is in use."
    fi
}

# DNS resolve — fallback chain, no hard deps
resolve_domain() {
    local domain="$1"
    local ip=""
    if command -v getent &>/dev/null; then
        ip=$(getent hosts "${domain}" 2>/dev/null | awk '{print $1}' | head -n 1)
    elif command -v host &>/dev/null; then
        ip=$(host "${domain}" 2>/dev/null | awk '/has address/ {print $4}' | head -n 1)
    elif command -v nslookup &>/dev/null; then
        ip=$(nslookup "${domain}" 2>/dev/null | awk '/^Address:/ && !/127/ {print $2}' | head -n 1)
    elif command -v dig &>/dev/null; then
        ip=$(dig +short "${domain}" 2>/dev/null | tail -n 1)
    fi
    echo "${ip}"
}

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT

# ============================================================================
#  INTERACTIVE PHASE
# ============================================================================

# ── [1/10] Prerequisites ───────────────────────────────────────────────────

check_prerequisites() {
    log_step 1 "Checking prerequisites"

    if [[ "${EUID}" -ne 0 ]]; then
        log_fail "This script must be run as root (use sudo)"
    fi
    log_ok "Running as root"

    if [[ ! -f /etc/os-release ]]; then
        log_fail "Cannot detect OS — /etc/os-release not found"
    fi
    # shellcheck source=/dev/null
    source /etc/os-release

    local id_lower="${ID,,}"
    local id_like_lower="${ID_LIKE:+${ID_LIKE,,}}"

    if [[ "${id_lower}" =~ (debian|ubuntu|mint|pop) ]] || [[ "${id_like_lower}" =~ debian ]]; then
        OS_FAMILY="debian"
        PKG_MANAGER="apt-get"
    elif [[ "${id_lower}" =~ (rhel|centos|rocky|alma|fedora|ol) ]] || [[ "${id_like_lower}" =~ (rhel|fedora) ]]; then
        OS_FAMILY="rhel"
        if command -v dnf &>/dev/null; then PKG_MANAGER="dnf"; else PKG_MANAGER="yum"; fi
    elif [[ "${id_lower}" =~ arch ]] || [[ "${id_like_lower}" =~ arch ]]; then
        OS_FAMILY="arch"
        PKG_MANAGER="pacman"
    else
        log_fail "Unsupported distribution: ${PRETTY_NAME:-${ID}}. Supported: Debian/Ubuntu, RHEL/Rocky/Fedora, Arch"
    fi
    log_ok "Detected OS: ${PRETTY_NAME:-${ID}} (${OS_FAMILY})"

    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)       log_fail "Unsupported architecture: $(uname -m). Supported: x86_64, aarch64" ;;
    esac
    log_ok "Architecture: $(uname -m) (${ARCH})"

    if ! command -v systemctl &>/dev/null || [[ ! -d /run/systemd/system ]]; then
        echo ""
        log_warn "This installer requires a systemd-based system."
        echo ""
        echo "  Yapper uses systemd units for:"
        echo "    - the main yapper-server service"
        echo "    - the optional automatic update timer"
        echo ""
        echo "  This machine does not appear to have a working systemd environment."
        echo ""
        echo "  How to fix it:"
        echo "    1. Run the installer on a Linux server that uses systemd."
        echo "    2. Or install/configure systemd on this machine first."
        echo "    3. Or install yapper-server manually without this installer."
        echo ""
        log_fail "systemd was not detected. Use a systemd-based host or do a manual Yapper installation."
    fi
    log_ok "systemd detected"

    for cmd in curl tar; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_info "Installing ${cmd}..."
            case "${OS_FAMILY}" in
                debian) apt-get update -qq && apt-get install -y -qq "${cmd}" ;;
                rhel)   ${PKG_MANAGER} install -y -q "${cmd}" ;;
                arch)   pacman -Sy --noconfirm "${cmd}" ;;
            esac
        fi
    done
    log_ok "Dependencies ready (curl, tar)"

    echo ""
}

# ── [2/10] License input ───────────────────────────────────────────────────

setup_license() {
    log_step 2 "License setup"
    echo ""
    echo -e "  ${BOLD}How to get your license:${RESET}"
    echo -e "    1. Log in to ${CYAN}https://yapper.gg${RESET}"
    echo -e "    2. Open ${BOLD}Licenses${RESET} from the menu"
    echo -e "    3. Click ${BOLD}View License${RESET} on the license you want to use"
    echo -e "    4. Copy the entire contents shown on that page"
    echo ""
    echo -e "  Paste your license below, then type ${BOLD}END${RESET} on its own line when finished:"
    echo ""

    LICENSE_CONTENT=""
    while IFS= read -r line </dev/tty; do
        [[ "${line}" == "END" ]] && break
        LICENSE_CONTENT+="${line}"$'\n'
    done

    if [[ -z "${LICENSE_CONTENT}" ]]; then
        log_fail "No license content provided"
    fi

    # Parse fields
    local has_domain_line=false
    local has_port_line=false

    while IFS= read -r line; do
        [[ "${line}" =~ ^#.*$ ]] && continue
        [[ -z "${line}" ]] && continue
        local key="${line%%=*}"
        local value="${line#*=}"
        case "${key}" in
            license_key)      LICENSE_KEY="${value}" ;;
            instance_domain)  INSTANCE_DOMAIN="${value}"; has_domain_line=true ;;
            instance_port)    INSTANCE_PORT="${value}"; has_port_line=true ;;
        esac
    done <<< "${LICENSE_CONTENT}"

    if [[ -z "${LICENSE_KEY}" ]]; then
        log_fail "License is missing 'license_key' field"
    fi
    log_ok "License key found"

    # Domain
    if [[ -z "${INSTANCE_DOMAIN}" ]]; then
        echo ""
        while true; do
            read -rp "  Enter the domain for this instance (e.g., chat.example.com): " INSTANCE_DOMAIN </dev/tty
            INSTANCE_DOMAIN="${INSTANCE_DOMAIN#http://}"
            INSTANCE_DOMAIN="${INSTANCE_DOMAIN#https://}"
            INSTANCE_DOMAIN="${INSTANCE_DOMAIN%/}"
            if [[ -z "${INSTANCE_DOMAIN}" ]]; then
                echo "  Domain cannot be empty."
            elif [[ "${INSTANCE_DOMAIN}" =~ [[:space:]] ]]; then
                echo "  Domain cannot contain spaces."
            else
                break
            fi
        done
    fi
    log_ok "Domain: ${INSTANCE_DOMAIN}"

    # Port
    if [[ -z "${INSTANCE_PORT}" ]]; then
        echo ""
        while true; do
            read -rp "  Enter the port for this instance (default 7880): " INSTANCE_PORT </dev/tty
            INSTANCE_PORT="${INSTANCE_PORT:-7880}"
            if ! [[ "${INSTANCE_PORT}" =~ ^[0-9]+$ ]]; then
                echo "  Port must be a number."; INSTANCE_PORT=""
            elif [[ "${INSTANCE_PORT}" -lt 1 || "${INSTANCE_PORT}" -gt 65534 ]]; then
                echo "  Port must be between 1 and 65534."; INSTANCE_PORT=""
            else
                break
            fi
        done
    else
        if ! [[ "${INSTANCE_PORT}" =~ ^[0-9]+$ ]] || [[ "${INSTANCE_PORT}" -lt 1 || "${INSTANCE_PORT}" -gt 65534 ]]; then
            log_fail "Invalid instance_port in license: ${INSTANCE_PORT} (must be 1-65534)"
        fi
    fi
    log_ok "Instance port: ${INSTANCE_PORT}"

    # Ask for server listen port (separate from the license instance_port)
    echo ""
    echo -e "  The server listen port is the local TCP port the Yapper binary binds to."
    echo -e "  This is different from the instance port in the license (which may be 443 behind a reverse proxy)."
    while true; do
        read -rp "  Yapper server listen port (default 7880): " SERVER_PORT </dev/tty
        SERVER_PORT="${SERVER_PORT:-7880}"
        if ! [[ "${SERVER_PORT}" =~ ^[0-9]+$ ]]; then
            echo "  Port must be a number."; SERVER_PORT=""
        elif [[ "${SERVER_PORT}" -lt 1 || "${SERVER_PORT}" -gt 65534 ]]; then
            echo "  Port must be between 1 and 65534."; SERVER_PORT=""
        else
            break
        fi
    done
    SERVER_RTC_PORT=$(( SERVER_PORT + 1 ))
    log_ok "Server listen port: ${SERVER_PORT}"
    log_ok "Server RTC port: ${SERVER_RTC_PORT}"

    # Check server ports are free
    require_free_tcp_port "${SERVER_PORT}" "Yapper server"
    require_free_tcp_port "${SERVER_RTC_PORT}" "Yapper RTC"
    log_ok "Ports ${SERVER_PORT} and ${SERVER_RTC_PORT} are available"

    # Reconstruct license with domain/port filled in
    FINAL_LICENSE=""
    while IFS= read -r line; do
        if [[ "${line}" =~ ^instance_domain= ]]; then
            FINAL_LICENSE+="instance_domain=${INSTANCE_DOMAIN}"$'\n'
        elif [[ "${line}" =~ ^instance_port= ]]; then
            FINAL_LICENSE+="instance_port=${INSTANCE_PORT}"$'\n'
        else
            FINAL_LICENSE+="${line}"$'\n'
        fi
    done <<< "${LICENSE_CONTENT}"

    ${has_domain_line} || FINAL_LICENSE+="instance_domain=${INSTANCE_DOMAIN}"$'\n'
    ${has_port_line}   || FINAL_LICENSE+="instance_port=${INSTANCE_PORT}"$'\n'

    echo ""
}

# ── [3/10] Options ──────────────────────────────────────────────────────────

collect_options() {
    log_step 3 "Installation options"

    if prompt_yes_no "Install Caddy as a reverse proxy?"; then
        INSTALL_CADDY=true

        # Domain — default to license domain
        echo ""
        while true; do
            read -rp "  Caddy domain [${INSTANCE_DOMAIN}]: " CADDY_DOMAIN </dev/tty
            CADDY_DOMAIN="${CADDY_DOMAIN:-${INSTANCE_DOMAIN}}"
            CADDY_DOMAIN="${CADDY_DOMAIN#http://}"
            CADDY_DOMAIN="${CADDY_DOMAIN#https://}"
            CADDY_DOMAIN="${CADDY_DOMAIN%/}"
            if [[ -n "${CADDY_DOMAIN}" && ! "${CADDY_DOMAIN}" =~ [[:space:]] ]]; then
                break
            fi
            echo "  Please enter a valid domain."
        done
        log_ok "Caddy domain: ${CADDY_DOMAIN}"

        if prompt_yes_no "Enable automatic SSL via Let's Encrypt?"; then
            CADDY_SSL=true

            # Check 80 + 443
            require_free_tcp_port 80 "Caddy HTTP (ACME)" "caddy_ssl"
            require_free_tcp_port 443 "Caddy HTTPS" "caddy_ssl"
            log_ok "Ports 80 and 443 are available"

            # Best-effort DNS check
            log_info "Checking DNS for ${CADDY_DOMAIN}..."
            local resolved_ip
            resolved_ip=$(resolve_domain "${CADDY_DOMAIN}")
            local my_ip
            my_ip=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)

            if [[ -n "${resolved_ip}" && -n "${my_ip}" && "${resolved_ip}" != "${my_ip}" ]]; then
                log_warn "${CADDY_DOMAIN} resolves to ${resolved_ip}, but this machine is ${my_ip}"
                log_warn "Let's Encrypt may fail if DNS does not point here"
            elif [[ -z "${resolved_ip}" ]]; then
                log_warn "Could not resolve ${CADDY_DOMAIN} — ensure DNS is configured"
            else
                log_ok "DNS looks good (${resolved_ip})"
            fi
        else
            # HTTP-only Caddy still needs port 80
            require_free_tcp_port 80 "Caddy HTTP"
            log_ok "Port 80 is available"
        fi
    else
        log_info "Skipping reverse proxy"
    fi

    echo ""
    echo "  Auto-update can check for a new approved Yapper release every 24 hours."
    echo "  If a new version is installed, Yapper will restart automatically."
    if prompt_yes_no "Enable automatic updates every 24 hours?" "yes"; then
        ENABLE_AUTO_UPDATE=true
        log_ok "Automatic updates enabled"
    else
        log_info "Automatic updates disabled"
    fi

    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD}  Starting installation — no more prompts from here${RESET}"
    echo -e "${BOLD}────────────────────────────────────────────────────────────${RESET}"
    echo ""
}

# ============================================================================
#  AUTOMATED PHASE
# ============================================================================

# ── [4/10] Download binary ─────────────────────────────────────────────────

download_binary() {
    log_step 4 "Downloading yapper-server"

    log_info "Fetching latest release..."
    local api_response
    api_response=$(curl -fsSL "${GITHUB_API}" 2>/dev/null) || log_fail "Failed to fetch release info from GitHub. Check your internet connection."

    VERSION=$(echo "${api_response}" | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "${VERSION}" ]]; then
        log_fail "Could not determine latest version"
    fi
    log_ok "Latest version: ${VERSION}"

    local archive_name="${REPO_NAME}_${VERSION}_linux_${ARCH}.tar.gz"
    local base_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VERSION}"
    local archive_url="${base_url}/${archive_name}"
    local checksum_url="${base_url}/checksums.txt"

    TMP_DIR=$(mktemp -d)

    log_info "Downloading ${archive_name}..."
    if ! curl -fSL -o "${TMP_DIR}/${archive_name}" "${archive_url}"; then
        log_fail "Failed to download ${archive_url}"
    fi
    log_ok "Downloaded"

    # Verify checksum
    if curl -fsSL -o "${TMP_DIR}/checksums.txt" "${checksum_url}" 2>/dev/null; then
        local expected
        expected=$(grep "${archive_name}" "${TMP_DIR}/checksums.txt" | awk '{print $1}')
        if [[ -n "${expected}" ]]; then
            local actual
            if command -v sha256sum &>/dev/null; then
                actual=$(sha256sum "${TMP_DIR}/${archive_name}" | awk '{print $1}')
            elif command -v shasum &>/dev/null; then
                actual=$(shasum -a 256 "${TMP_DIR}/${archive_name}" | awk '{print $1}')
            else
                log_warn "No sha256sum or shasum available — skipping verification"
                actual="${expected}"
            fi
            if [[ "${expected}" != "${actual}" ]]; then
                log_fail "SHA256 checksum mismatch!\n  Expected: ${expected}\n  Got:      ${actual}"
            fi
            log_ok "SHA256 checksum verified"
        else
            log_warn "Archive not found in checksums.txt — skipping verification"
        fi
    else
        log_warn "checksums.txt not available — skipping verification"
    fi

    # Extract
    install -d -m 755 "${INSTALL_DIR}"
    tar xzf "${TMP_DIR}/${archive_name}" -C "${TMP_DIR}"

    if [[ -f "${TMP_DIR}/${BINARY_NAME}" ]]; then
        mv "${TMP_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    else
        local found
        found=$(find "${TMP_DIR}" -name "${BINARY_NAME}" -type f | head -n 1)
        if [[ -z "${found}" ]]; then
            log_fail "Binary '${BINARY_NAME}' not found in release archive"
        fi
        mv "${found}" "${INSTALL_DIR}/${BINARY_NAME}"
    fi

    chown root:root "${INSTALL_DIR}/${BINARY_NAME}"
    chmod 755 "${INSTALL_DIR}/${BINARY_NAME}"
    log_ok "Installed to ${INSTALL_DIR}/${BINARY_NAME}"

    echo ""
}

# ── [5/10] Runtime dependencies ────────────────────────────────────────────

# Static mapping from a missing shared library to the providing package on
# each supported distro. The yapper binary only links against glibc today,
# but a few extras are listed in case a future build pulls them in.
# Echoes the package name on stdout, or nothing if the lib is not in the map.
guess_package_for_lib() {
    local lib="$1"
    case "${OS_FAMILY}" in
        debian)
            case "${lib}" in
                libc.so.*|ld-linux*)              echo "libc6" ;;
                libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*) echo "libc6" ;;
                libstdc++.so.*)                   echo "libstdc++6" ;;
                libgcc_s.so.*)                    echo "libgcc-s1" ;;
                libssl.so.*|libcrypto.so.*)       echo "libssl3" ;;
                libz.so.*)                        echo "zlib1g" ;;
            esac
            ;;
        rhel)
            case "${lib}" in
                libc.so.*|ld-linux*)              echo "glibc" ;;
                libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*) echo "glibc" ;;
                libstdc++.so.*)                   echo "libstdc++" ;;
                libgcc_s.so.*)                    echo "libgcc" ;;
                libssl.so.*|libcrypto.so.*)       echo "openssl-libs" ;;
                libz.so.*)                        echo "zlib" ;;
            esac
            ;;
        arch)
            case "${lib}" in
                libc.so.*|ld-linux*)              echo "glibc" ;;
                libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*) echo "glibc" ;;
                libstdc++.so.*|libgcc_s.so.*)     echo "gcc-libs" ;;
                libssl.so.*|libcrypto.so.*)       echo "openssl" ;;
                libz.so.*)                        echo "zlib" ;;
            esac
            ;;
    esac
}

install_packages_quiet() {
    local -a pkgs=("$@")
    [[ "${#pkgs[@]}" -gt 0 ]] || return 0
    case "${OS_FAMILY}" in
        debian) apt-get install -y -qq "${pkgs[@]}" &>/dev/null ;;
        rhel)   ${PKG_MANAGER} install -y -q "${pkgs[@]}" &>/dev/null ;;
        arch)   pacman -S --noconfirm "${pkgs[@]}" &>/dev/null ;;
    esac
}

print_manual_lib_instructions() {
    local -a missing_list=("$@")

    local install_cmd lookup_hint
    case "${OS_FAMILY}" in
        debian) install_cmd="sudo apt-get install -y"; lookup_hint="https://packages.debian.org or https://packages.ubuntu.com" ;;
        rhel)   install_cmd="sudo ${PKG_MANAGER} install -y"; lookup_hint="sudo ${PKG_MANAGER} provides '*/<libname>'" ;;
        arch)   install_cmd="sudo pacman -S"; lookup_hint="https://archlinux.org/packages/" ;;
    esac

    # Split the still-missing libs into "we know the package" and "we don't"
    local -a known_pkgs=() unknown_libs=()
    local lib pkg already
    for lib in "${missing_list[@]}"; do
        pkg="$(guess_package_for_lib "${lib}")"
        if [[ -n "${pkg}" ]]; then
            already=false
            for existing in "${known_pkgs[@]:-}"; do
                [[ "${existing}" == "${pkg}" ]] && { already=true; break; }
            done
            ${already} || known_pkgs+=("${pkg}")
        else
            unknown_libs+=("${lib}")
        fi
    done

    echo ""
    echo -e "  ${BOLD}How to install the missing libraries:${RESET}"
    if [[ "${#known_pkgs[@]}" -gt 0 ]]; then
        echo -e "    Run:"
        echo -e "      ${CYAN}${install_cmd} ${known_pkgs[*]}${RESET}"
    fi
    if [[ "${#unknown_libs[@]}" -gt 0 ]]; then
        echo ""
        echo -e "  These libraries are also missing and the installer doesn't know which package provides them:"
        for lib in "${unknown_libs[@]}"; do
            log_info "  - ${lib}"
        done
        echo -e "    Look them up: ${CYAN}${lookup_hint}${RESET}"
    fi
    echo ""
    echo -e "  Once installed, re-run this installer."
}

install_runtime_deps() {
    log_step 5 "Checking runtime dependencies"

    local bin="${INSTALL_DIR}/${BINARY_NAME}"

    # Check if binary is statically linked
    if command -v file &>/dev/null; then
        if file "${bin}" | grep -qi 'statically linked'; then
            log_ok "Binary is statically linked — no runtime libraries needed"
            echo ""
            return
        fi
    fi

    # Dynamic binary — install known runtime packages
    log_info "Installing runtime packages..."
    case "${OS_FAMILY}" in
        debian)
            apt-get update -qq &>/dev/null
            apt-get install -y -qq ca-certificates libc6 libstdc++6 &>/dev/null
            ;;
        rhel)
            ${PKG_MANAGER} install -y -q ca-certificates glibc libstdc++ &>/dev/null
            ;;
        arch)
            pacman -Sy --noconfirm ca-certificates glibc gcc-libs &>/dev/null
            ;;
    esac
    log_ok "Runtime packages installed"

    if ! command -v ldd &>/dev/null; then
        log_warn "ldd not available — skipping library verification"
        echo ""
        return
    fi

    local ldd_output missing
    ldd_output=$(ldd "${bin}" 2>&1 || true)

    if echo "${ldd_output}" | grep -qi "not a dynamic executable"; then
        log_ok "Binary is statically linked — no runtime libraries needed"
        echo ""
        return
    fi

    # Glibc version mismatch: lines like
    #   ./binary: /lib/.../libc.so.6: version `GLIBC_2.34' not found (required by ...)
    # Cannot be fixed by installing a package — the OS itself is too old.
    local required_glibc
    required_glibc=$(echo "${ldd_output}" \
        | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
        | sed 's/^GLIBC_//' \
        | sort -V | tail -1)
    if [[ -n "${required_glibc}" ]]; then
        local system_glibc
        system_glibc=$(ldd --version 2>&1 | head -1 | awk '{print $NF}')
        echo ""
        log_warn "This system's glibc is too old for this build of yapper-server."
        log_info "  Required: glibc ${required_glibc} or newer"
        log_info "  Installed: glibc ${system_glibc:-unknown}"
        echo ""
        echo -e "  ${BOLD}This cannot be fixed by installing a package.${RESET}"
        echo -e "  glibc is the base system C library; replacing it on a running OS is unsafe."
        echo ""
        echo -e "  ${BOLD}Recommended OS versions (glibc ≥ 2.34):${RESET}"
        echo -e "    • Ubuntu 22.04 LTS or newer        (glibc 2.35+)"
        echo -e "    • Debian 12 'Bookworm' or newer    (glibc 2.36+)"
        echo -e "    • RHEL / Rocky / AlmaLinux 9+      (glibc 2.34+)"
        echo -e "    • Fedora 35 or newer"
        echo -e "    • Arch Linux (rolling)"
        echo ""
        echo -e "  Upgrade the OS and re-run this installer."
        echo ""
        log_fail "Unsupported glibc version"
    fi

    # Truly-missing libraries match the "=> not found" form only.
    missing=$(echo "${ldd_output}" | awk '/=> not found/ {print $1}')
    if [[ -z "${missing}" ]]; then
        log_ok "All shared library dependencies are present"
        echo ""
        return
    fi

    log_warn "Some shared libraries are still missing:"
    local -a missing_arr=()
    while IFS= read -r lib; do
        if [[ -n "${lib}" ]]; then
            log_info "  - ${lib}"
            missing_arr+=("${lib}")
        fi
    done <<< "${missing}"

    # Try to auto-install the packages we can map from the lib name
    local -a auto_pkgs=()
    local lib pkg already
    for lib in "${missing_arr[@]}"; do
        pkg="$(guess_package_for_lib "${lib}")"
        if [[ -n "${pkg}" ]]; then
            already=false
            for existing in "${auto_pkgs[@]:-}"; do
                [[ "${existing}" == "${pkg}" ]] && { already=true; break; }
            done
            ${already} || auto_pkgs+=("${pkg}")
        fi
    done

    if [[ "${#auto_pkgs[@]}" -gt 0 ]]; then
        log_info "Trying to install: ${auto_pkgs[*]}"
        if install_packages_quiet "${auto_pkgs[@]}"; then
            log_ok "Installed ${auto_pkgs[*]}"
        else
            log_warn "Auto-install failed for one or more of: ${auto_pkgs[*]}"
        fi

        # Re-check
        ldd_output=$(ldd "${bin}" 2>&1 || true)
        missing=$(echo "${ldd_output}" | awk '/=> not found/ {print $1}')
        if [[ -z "${missing}" ]]; then
            log_ok "All shared library dependencies are now present"
            echo ""
            return
        fi
    fi

    # Still missing → show clear manual instructions and abort
    log_warn "These libraries are still missing:"
    local -a still_missing=()
    while IFS= read -r lib; do
        if [[ -n "${lib}" ]]; then
            log_info "  - ${lib}"
            still_missing+=("${lib}")
        fi
    done <<< "${missing}"

    print_manual_lib_instructions "${still_missing[@]}"
    echo ""
    log_fail "Cannot continue with missing shared libraries"
}

# ── [6/10] System user ─────────────────────────────────────────────────────

create_system_user() {
    log_step 6 "Creating system user"

    local nologin_path
    nologin_path="$(command -v nologin 2>/dev/null || true)"
    [[ -n "${nologin_path}" ]] || nologin_path="/usr/sbin/nologin"

    if ! getent group "${SERVICE_USER}" >/dev/null 2>&1; then
        groupadd --system "${SERVICE_USER}"
        log_ok "Created group '${SERVICE_USER}'"
    fi

    if id -u "${SERVICE_USER}" &>/dev/null; then
        log_ok "User '${SERVICE_USER}' already exists"
    else
        useradd --system --gid "${SERVICE_USER}" --no-create-home --shell "${nologin_path}" "${SERVICE_USER}"
        log_ok "Created user '${SERVICE_USER}'"
    fi

    chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"
    log_ok "Ownership set on ${INSTALL_DIR}"

    echo ""
}

# ── [7/10] Configuration ───────────────────────────────────────────────────

write_config() {
    log_step 7 "Writing configuration"

    cat > "${CONFIG_FILE}" <<YAML
port: ${SERVER_PORT}

rtc:
  use_external_ip: false
  tcp_port: ${SERVER_RTC_PORT}
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
YAML
    chown "${SERVICE_USER}:${SERVICE_USER}" "${CONFIG_FILE}"
    chmod 644 "${CONFIG_FILE}"
    log_ok "Config written to ${CONFIG_FILE}"

    install -d -m 755 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${DATA_DIR}"
    echo -n "${FINAL_LICENSE}" > "${LICENSE_FILE}"
    chmod 600 "${LICENSE_FILE}"
    chown "${SERVICE_USER}:${SERVICE_USER}" "${LICENSE_FILE}"
    log_ok "License written to ${LICENSE_FILE}"

    echo ""
}

# ── [8/10] Systemd service ─────────────────────────────────────────────────

install_systemd_service() {
    log_step 8 "Installing systemd service"

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Yapper Server
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${BINARY_NAME} --config ${CONFIG_FILE}
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
    systemctl enable "${SERVICE_NAME}" --quiet
    systemctl start "${SERVICE_NAME}"

    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_ok "Service installed, enabled, and started"
    else
        log_warn "Service may have failed to start. Showing recent logs:"
        journalctl -u "${SERVICE_NAME}" --no-pager -n 20 >&2 || true
        log_fail "Service failed to start — check logs above"
    fi

    echo ""
}

# ── [9/10] Automatic Updates ───────────────────────────────────────────────

setup_auto_update() {
    log_step 9 "Automatic updates"

    if [[ "${ENABLE_AUTO_UPDATE}" != true ]]; then
        systemctl disable --now "${UPDATE_UNIT_NAME}.timer" --quiet &>/dev/null || true
        rm -f "${UPDATE_SCRIPT}" "${UPDATE_SERVICE_FILE}" "${UPDATE_TIMER_FILE}"
        systemctl daemon-reload
        log_info "Skipping automatic updates"
        echo ""
        return
    fi

    install -d -m 755 "$(dirname "${UPDATE_SCRIPT}")"
    cat > "${UPDATE_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

BINARY_PATH="${INSTALL_DIR}/${BINARY_NAME}"
DATA_DIR="${DATA_DIR}"
LICENSE_FILE="${LICENSE_FILE}"
SERVICE_NAME="${SERVICE_NAME}"

before_version="\$("\${BINARY_PATH}" --version 2>/dev/null || true)"
if [[ -z "\${before_version}" ]]; then
    echo "Could not determine the current Yapper version" >&2
    exit 1
fi

"\${BINARY_PATH}" update --yes --data-dir "\${DATA_DIR}" --license-file "\${LICENSE_FILE}"

after_version="\$("\${BINARY_PATH}" --version 2>/dev/null || true)"
if [[ -z "\${after_version}" ]]; then
    echo "Could not determine the updated Yapper version" >&2
    exit 1
fi

if [[ "\${after_version}" != "\${before_version}" ]]; then
    echo "Yapper updated: \${before_version} -> \${after_version}"
    systemctl restart "\${SERVICE_NAME}"
    echo "Restarted \${SERVICE_NAME}"
else
    echo "Yapper is already up to date (\${after_version})"
fi
EOF
    chmod 755 "${UPDATE_SCRIPT}"
    chown root:root "${UPDATE_SCRIPT}"
    log_ok "Update helper installed"

    cat > "${UPDATE_SERVICE_FILE}" <<EOF
[Unit]
Description=Yapper update check and apply
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${UPDATE_SCRIPT}
EOF

    cat > "${UPDATE_TIMER_FILE}" <<EOF
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
    systemctl enable --now "${UPDATE_UNIT_NAME}.timer" --quiet

    sleep 1
    if systemctl is-active --quiet "${UPDATE_UNIT_NAME}.timer"; then
        log_ok "Automatic update timer installed and started"
    else
        log_warn "Automatic update timer may have failed to start. Showing status:"
        systemctl status "${UPDATE_UNIT_NAME}.timer" --no-pager >&2 || true
        log_fail "Automatic updates could not be enabled"
    fi

    echo ""
}

# ── [10/10] Reverse Proxy ───────────────────────────────────────────────────

setup_reverse_proxy() {
    log_step 10 "Reverse proxy"

    # SELinux
    if command -v getenforce &>/dev/null; then
        if [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
            if command -v restorecon &>/dev/null; then
                restorecon -Rv "${INSTALL_DIR}" &>/dev/null
                log_ok "SELinux context restored"
            else
                log_warn "SELinux is enforcing — you may need to set contexts manually on ${INSTALL_DIR}"
            fi
        fi
    fi

    # ── Caddy ──
    if [[ "${INSTALL_CADDY}" != true ]]; then
        echo ""
        return
    fi

    log_info "Installing Caddy..."
    case "${OS_FAMILY}" in
        debian)
            apt-get install -y -qq gnupg ca-certificates debian-keyring debian-archive-keyring apt-transport-https &>/dev/null
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list &>/dev/null
            apt-get update -qq &>/dev/null
            apt-get install -y -qq caddy &>/dev/null
            ;;
        rhel)
            ${PKG_MANAGER} install -y -q 'dnf-command(copr)' &>/dev/null 2>&1 || true
            ${PKG_MANAGER} copr enable -y @caddy/caddy &>/dev/null 2>&1 || true
            ${PKG_MANAGER} install -y -q caddy &>/dev/null
            ;;
        arch)
            pacman -Sy --noconfirm caddy &>/dev/null
            ;;
    esac
    log_ok "Caddy installed"

    # Write Caddyfile
    mkdir -p /etc/caddy
    if [[ "${CADDY_SSL}" == true ]]; then
        cat > /etc/caddy/Caddyfile <<CADDY
${CADDY_DOMAIN} {
    reverse_proxy localhost:${SERVER_PORT}
}
CADDY
        log_ok "Caddyfile written with automatic SSL"
    else
        cat > /etc/caddy/Caddyfile <<CADDY
{
    auto_https off
}

http://${CADDY_DOMAIN} {
    reverse_proxy localhost:${SERVER_PORT}
}
CADDY
        log_ok "Caddyfile written (no SSL)"
    fi

    # Validate config
    if caddy validate --config /etc/caddy/Caddyfile &>/dev/null; then
        log_ok "Caddyfile validated"
    else
        log_warn "Caddyfile validation failed — check /etc/caddy/Caddyfile"
    fi

    systemctl enable caddy --quiet
    systemctl restart caddy

    sleep 2
    if systemctl is-active --quiet caddy; then
        log_ok "Caddy started"
    else
        log_warn "Caddy may have failed to start"
        journalctl -u caddy --no-pager -n 10 >&2 || true
    fi

    echo ""
}

# ============================================================================
#  Summary
# ============================================================================

print_summary() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Yapper Server — Installation Complete${RESET}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  Binary:    ${INSTALL_DIR}/${BINARY_NAME}"
    echo -e "  Config:    ${CONFIG_FILE}"
    echo -e "  License:   ${LICENSE_FILE}"
    echo -e "  Service:   ${SERVICE_NAME}"
    echo ""
    echo -e "  Domain:    ${INSTANCE_DOMAIN}"
    echo -e "  Instance:  ${INSTANCE_DOMAIN}:${INSTANCE_PORT} (license)"
    echo -e "  Listen:    ${SERVER_PORT}/tcp"
    echo -e "  RTC:       ${SERVER_RTC_PORT}/tcp"
    echo -e "  Media:     50000-60000/udp"
    if [[ "${ENABLE_AUTO_UPDATE}" == true ]]; then
        echo -e "  Updates:   enabled (${UPDATE_UNIT_NAME}.timer)"
    else
        echo -e "  Updates:   disabled"
    fi
    if [[ "${INSTALL_CADDY}" == true ]]; then
        echo ""
        echo -e "  Caddy:     ${CADDY_DOMAIN}"
        if [[ "${CADDY_SSL}" == true ]]; then
            echo -e "  SSL:       Let's Encrypt (automatic)"
        else
            echo -e "  SSL:       disabled"
        fi
    fi
    echo ""
    echo -e "  ${BOLD}Useful commands:${RESET}"
    echo -e "    systemctl status ${SERVICE_NAME}"
    echo -e "    journalctl -u ${SERVICE_NAME} -f"
    echo -e "    systemctl restart ${SERVICE_NAME}"
    if [[ "${ENABLE_AUTO_UPDATE}" == true ]]; then
        echo -e "    systemctl status ${UPDATE_UNIT_NAME}.timer"
        echo -e "    journalctl -u ${UPDATE_UNIT_NAME}.service -f"
    fi
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
    echo ""
}

# ============================================================================
#  Main
# ============================================================================

main() {
    echo ""
    echo -e "${BOLD}Yapper Server Installer${RESET}"
    echo -e "https://yapper.gg"
    echo ""

    # ── Interactive phase ──
    check_prerequisites
    setup_license
    collect_options

    # ── Automated phase ──
    download_binary
    install_runtime_deps
    create_system_user
    write_config
    install_systemd_service
    setup_auto_update
    setup_reverse_proxy
    print_summary
}

main "$@"
