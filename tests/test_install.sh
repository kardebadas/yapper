#!/usr/bin/env bash
# Dependency-free unit tests for install.sh.
# Loads install.sh as a library (YAPPER_INSTALL_LIB short-circuits main).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export YAPPER_INSTALL_LIB=1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/install.sh"
set +e  # we assert on non-zero return codes below

PASS=0
FAIL=0

assert_eq() { # expected actual message
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $3"
    echo "      expected: [$1]"
    echo "      actual:   [$2]"
  fi
}

assert_rc() { # expected_rc actual_rc message
  assert_eq "$1" "$2" "$3"
}

# --- A1: parse_args + usage ---------------------------------------------------

( parse_args --help ) >/dev/null 2>&1
assert_rc 0 "$?" "parse_args --help exits 0"

( parse_args --bogus-flag ) >/dev/null 2>&1
assert_rc 1 "$?" "parse_args rejects unknown flag with exit 1"

NON_INTERACTIVE=false
parse_args --license=Zm9v --server-port=9000 --install-caddy --caddy-domain=x.test --caddy-ssl --no-auto-update >/dev/null 2>&1
assert_eq "true"   "${NON_INTERACTIVE}" "--license sets NON_INTERACTIVE"
assert_eq "Zm9v"   "${LICENSE_B64}"     "--license captured"
assert_eq "9000"   "${SERVER_PORT}"     "--server-port captured"
assert_eq "true"   "${INSTALL_CADDY}"   "--install-caddy captured"
assert_eq "x.test" "${CADDY_DOMAIN}"    "--caddy-domain captured"
assert_eq "true"   "${CADDY_SSL}"       "--caddy-ssl captured"
assert_eq "false"  "${ENABLE_AUTO_UPDATE}" "--no-auto-update captured"

( parse_args --license= ) >/dev/null 2>&1
assert_rc 1 "$?" "parse_args rejects empty --license value"

( parse_args --server-port=abc ) >/dev/null 2>&1
assert_rc 1 "$?" "parse_args rejects non-numeric --server-port"

( parse_args --server-port=70000 ) >/dev/null 2>&1
assert_rc 1 "$?" "parse_args rejects out-of-range --server-port"

# --- A2: parse_license_content + reconstruct_final_license --------------------

LICENSE_CONTENT=$'# License L1\nlicense_key=ABC123\ninstance_domain=chat.test\ninstance_port=7880\n'
LICENSE_KEY=""; INSTANCE_DOMAIN=""; INSTANCE_PORT=""
has_domain_line=false; has_port_line=false
parse_license_content
assert_eq "ABC123"    "${LICENSE_KEY}"      "parse_license_content reads license_key"
assert_eq "chat.test" "${INSTANCE_DOMAIN}"  "parse_license_content reads instance_domain"
assert_eq "7880"      "${INSTANCE_PORT}"    "parse_license_content reads instance_port"

FINAL_LICENSE=""
INSTANCE_DOMAIN="new.test"; INSTANCE_PORT="443"
reconstruct_final_license
case "${FINAL_LICENSE}" in
  *"instance_domain=new.test"*) assert_eq "ok" "ok" "reconstruct rewrites instance_domain" ;;
  *) assert_eq "ok" "miss" "reconstruct rewrites instance_domain" ;;
esac
case "${FINAL_LICENSE}" in
  *"instance_port=443"*) assert_eq "ok" "ok" "reconstruct rewrites instance_port" ;;
  *) assert_eq "ok" "miss" "reconstruct rewrites instance_port" ;;
esac
case "${FINAL_LICENSE}" in
  *"license_key=ABC123"*) assert_eq "ok" "ok" "reconstruct preserves license_key" ;;
  *) assert_eq "ok" "miss" "reconstruct preserves license_key" ;;
esac

# reconstruct appends domain/port lines when the source license omits them
LICENSE_CONTENT=$'license_key=K2\n'
LICENSE_KEY=""; INSTANCE_DOMAIN=""; INSTANCE_PORT=""
has_domain_line=false; has_port_line=false
parse_license_content >/dev/null 2>&1
INSTANCE_DOMAIN="appended.test"; INSTANCE_PORT="8080"
reconstruct_final_license
case "${FINAL_LICENSE}" in
  *"instance_domain=appended.test"*) assert_eq "ok" "ok" "reconstruct appends missing instance_domain" ;;
  *) assert_eq "ok" "miss" "reconstruct appends missing instance_domain" ;;
esac
case "${FINAL_LICENSE}" in
  *"instance_port=8080"*) assert_eq "ok" "ok" "reconstruct appends missing instance_port" ;;
  *) assert_eq "ok" "miss" "reconstruct appends missing instance_port" ;;
esac

# --- A3: base64 read + is_valid_port + non-interactive setup_license ----------

LICENSE_B64="$(printf '%s' $'license_key=K9\ninstance_domain=a.test\ninstance_port=7880\n' | base64 | tr -d '\n')"
LICENSE_CONTENT=""
read_license_from_base64
case "${LICENSE_CONTENT}" in
  *"license_key=K9"*) assert_eq "ok" "ok" "read_license_from_base64 decodes blob" ;;
  *) assert_eq "ok" "miss" "read_license_from_base64 decodes blob" ;;
esac

is_valid_port 7880;  assert_rc 0 "$?" "is_valid_port accepts 7880"
is_valid_port 0;     assert_rc 1 "$?" "is_valid_port rejects 0"
is_valid_port 70000; assert_rc 1 "$?" "is_valid_port rejects 70000"
is_valid_port abc;   assert_rc 1 "$?" "is_valid_port rejects non-numeric"
is_valid_port 1;     assert_rc 0 "$?" "is_valid_port accepts 1 (min)"
is_valid_port 65534; assert_rc 0 "$?" "is_valid_port accepts 65534 (max)"
is_valid_port 65535; assert_rc 1 "$?" "is_valid_port rejects 65535"

# Happy path: full non-interactive setup_license.
# The require_free_tcp_port stub is defined INSIDE the subshell so it does not
# leak into later test blocks; setup_license sets globals in the same subshell,
# and the echo runs only on success (&&) so a silent failure can't false-pass.
NON_INTERACTIVE=true
LICENSE_KEY=""; INSTANCE_DOMAIN=""; INSTANCE_PORT=""; SERVER_PORT=""; FINAL_LICENSE=""
LICENSE_B64="$(printf '%s' $'license_key=K9\ninstance_domain=a.test\ninstance_port=7880\n' | base64 | tr -d '\n')"
_a3_tmp="$(mktemp)"
( require_free_tcp_port() { :; }; setup_license >/dev/null 2>&1 && echo "${INSTANCE_DOMAIN}|${INSTANCE_PORT}|${SERVER_PORT}" ) > "${_a3_tmp}"
assert_eq "a.test|7880|7880" "$(cat "${_a3_tmp}")" "non-interactive setup_license fills domain/port/server"
rm -f "${_a3_tmp}"

# Failure path: missing license_key must exit non-zero.
NON_INTERACTIVE=true
LICENSE_B64="$(printf '%s' $'instance_domain=a.test\n' | base64 | tr -d '\n')"
LICENSE_KEY=""
( setup_license >/dev/null 2>&1 )
assert_rc 1 "$?" "non-interactive setup_license fails when license_key missing"

# --- A4: caddy_expected_port + apply_noninteractive_caddy_port ----------------

CADDY_SSL=true;  assert_eq "443" "$(caddy_expected_port)" "caddy_expected_port = 443 with SSL"
CADDY_SSL=false; assert_eq "80"  "$(caddy_expected_port)" "caddy_expected_port = 80 without SSL"

INSTALL_CADDY=true; CADDY_SSL=true; INSTANCE_PORT="7880"
FINAL_LICENSE=$'license_key=K9\ninstance_domain=a.test\ninstance_port=7880\n'
apply_noninteractive_caddy_port >/dev/null 2>&1
assert_eq "443" "${INSTANCE_PORT}" "apply_noninteractive_caddy_port sets INSTANCE_PORT=443"
case "${FINAL_LICENSE}" in
  *"instance_port=443"*) assert_eq "ok" "ok" "apply_noninteractive_caddy_port rewrites FINAL_LICENSE" ;;
  *) assert_eq "ok" "miss" "apply_noninteractive_caddy_port rewrites FINAL_LICENSE" ;;
esac
case "${FINAL_LICENSE}" in
  *"instance_port=7880"*) assert_eq "ok" "miss" "apply_noninteractive_caddy_port removes old port from FINAL_LICENSE" ;;
  *) assert_eq "ok" "ok" "apply_noninteractive_caddy_port removes old port from FINAL_LICENSE" ;;
esac

INSTALL_CADDY=false; INSTANCE_PORT="7880"
FINAL_LICENSE=$'instance_port=7880\n'
apply_noninteractive_caddy_port >/dev/null 2>&1
assert_eq "7880" "${INSTANCE_PORT}" "apply_noninteractive_caddy_port is a no-op without Caddy"

echo ""
echo "RESULT: PASS=${PASS} FAIL=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
