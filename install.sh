#!/bin/bash

set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

################################################################################
# Determine whether colors should be enabled for a specific file descriptor.
#
# Precedence:
#   1. NO_COLOR       -> disable
#   2. FORCE_COLOR=0  -> disable
#   3. FORCE_COLOR    -> enable
#   4. TTY            -> enable
#   5. otherwise      -> disable
################################################################################

readonly COLOR_NORMAL=$'\e[0m'
readonly COLOR_ERROR=$'\e[31m'
readonly COLOR_SUCCESS=$'\e[32m'
readonly COLOR_WARNING=$'\e[33m'
readonly COLOR_PRIMARY=$'\e[34m'

color_enabled() {
	local fd="$1"

	if [[ -n "${NO_COLOR:-}" ]]; then
		return 1
	fi

	if [[ "${FORCE_COLOR:-}" == "0" ]]; then
		return 1
	fi

	if [[ -n "${FORCE_COLOR:-}" ]]; then
		return 0
	fi

	[[ -t "$fd" ]]
}

NO="" EO="" SO="" WO="" PO="" NE="" EE="" SE="" WE="" PE=""

if color_enabled 1; then
	NO="$COLOR_NORMAL"
	EO="$COLOR_ERROR"
	SO="$COLOR_SUCCESS"
	WO="$COLOR_WARNING"
	PO="$COLOR_PRIMARY"
fi

if color_enabled 2; then
	NE="$COLOR_NORMAL"
	EE="$COLOR_ERROR"
	SE="$COLOR_SUCCESS"
	WE="$COLOR_WARNING"
	PE="$COLOR_PRIMARY"
fi

# shellcheck disable=SC2034
readonly NO EO SO WO PO NE EE SE WE PE

################################################################################
# Helpers:
################################################################################

action() {
	printf "%sACTION:%s %s... " "$PO" "$NO" "$1"
}

success() {
	printf "%sDONE%s\n" "$SO" "$NO"
}

failed() {
	printf "%sFAILED%s\n" "$EO" "$NO"
}

error() {
	printf "%sERROR:%s %s\n" "$EE" "$NE" "$1" >&2
	cat "$2" >&2
}

exit_success() {
	printf "%sSUCCESS:%s %s\n" "$SO" "$NO" "$1"
	exit 0
}

exit_error() {
	printf "%sERROR:%s %s\n" "$EE" "$NE" "$1" >&2
	exit 1
}

check_cmd() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		exit_error "Command '$cmd' not found. Please install it and retry."
	fi
}

################################################################################
# OS Validation:
################################################################################

if [[ "$EUID" -ne 0 ]]; then
	exit_error "This script must be run as root."
fi

if [[ ! -f "/etc/os-release" ]]; then
	exit_error "File /etc/os-release not found."
fi

if [[ ! -r "/etc/os-release" ]]; then
	exit_error "File /etc/os-release not readable."
fi

readonly INFO_FILE="/etc/os-release"
# shellcheck source=/dev/null
source "$INFO_FILE"

if [[ "${ID:-}" != "ubuntu" ]]; then
	exit_error "This script supports Ubuntu only."
fi

if [[ -z "${VERSION_ID:-}" ]]; then
	exit_error "Variable VERSION_ID not set in $INFO_FILE."
fi

if [[ -z "${VERSION_CODENAME:-}" ]]; then
	exit_error "Variable VERSION_CODENAME not set in $INFO_FILE."
fi

check_cmd "dpkg"

if ! dpkg --compare-versions "$VERSION_ID" ge "24.04"; then
	exit_error "This script supports Ubuntu 24.04 or later."
fi

check_cmd "apt-get"
check_cmd "curl"
check_cmd "gpg"
check_cmd "install"
check_cmd "mktemp"

################################################################################
# Functions:
################################################################################

download_key() {
	local out="$1"
	local key="$2"

	action "Downloading key from $KEY_LINK"

	if ! curl -sfLSo "$key" "$KEY_LINK" 2>"$out"; then
		failed
		error "Failed to download key from $KEY_LINK" "$out"
		exit 1
	fi

	success
}

validate_key() {
	local out="$1"
	local key="$2"
	local inf="$3"

	action "Validating key for $REP_NAME"

	if ! gpg --batch --no-keyring --no-options --no-tty --trust-model always --show-keys --with-colons \
		"$key" </dev/null 2>"$out" >"$inf"; then
		failed
		error "Failed to validate key for $REP_NAME" "$out"
		exit 1
	fi

	local -a fields=()
	local -a fingerprints=()
	local field
	local fingerprint
	local primary=false

	if ! while IFS=: read -ra fields; do
		field="${fields[0]:-}"
		fingerprint="${fields[9]:-}"

		if [[ "$field" == "pub" ]]; then
			primary=true
			continue
		fi

		if [[ "$field" == "sub" ]]; then
			primary=false
			continue
		fi

		if [[ "$field" == "fpr" && -n "$fingerprint" && "$primary" == true ]]; then
			fingerprints+=("$fingerprint")
			primary=false
		fi
	done 2>"$out" <"$inf"; then
		failed
		error "Failed to read key information for $REP_NAME" "$out"
		exit 1
	fi

	if [[ "${#fingerprints[@]}" -eq 0 ]]; then
		failed
		error "No primary key fingerprints found for $REP_NAME" "$out"
		exit 1
	fi

	local found
	local allowed

	for found in "${fingerprints[@]}"; do
		local valid=false

		for allowed in "${KEY_FING[@]}"; do
			if [[ "$found" == "$allowed" ]]; then
				valid=true
				break
			fi
		done

		if [[ "$valid" == false ]]; then
			failed
			error "Untrusted primary key fingerprint found for $REP_NAME: $found" "$out"
			exit 1
		fi
	done

	success
}

install_key() {
	local out="$1"
	local key="$2"
	local header

	action "Installing key for $REP_NAME"

	if ! IFS= read -rN 36 header 2>"$out" <"$key"; then
		failed
		error "Failed to inspect key format for $REP_NAME" "$out"
		exit 1
	fi

	if [[ "$header" == "-----BEGIN PGP PUBLIC KEY BLOCK-----" ]]; then
		KEY_NAME="$REP_NAME.asc"
	else
		KEY_NAME="$REP_NAME.gpg"
	fi

	if ! install -Dm 0644 "$key" "$KEY_PATH$KEY_NAME" 2>"$out"; then
		failed
		error "Failed to install key for $REP_NAME" "$out"
		exit 1
	fi

	success
}

install_repo() {
	local out="$1"
	local tmp="$2"
	local info

	local -a rep_info=(
		"Types: deb"
		"URIs: $REP_LINK"
		"Suites: cloud-sdk"
		"Components: main"
		"Signed-By: $KEY_PATH$KEY_NAME"
	)

	printf -v info "%s\n" "${rep_info[@]}"

	action "Installing repository for $REP_NAME"

	if ! printf "%s" "$info" 2>"$out" >"$tmp"; then
		failed
		error "Failed to prepare repository for $REP_NAME" "$out"
		exit 1
	fi

	if ! install -Dm 0644 "$tmp" "$REP_PATH" 2>"$out"; then
		failed
		error "Failed to install repository for $REP_NAME" "$out"
		exit 1
	fi

	success
}

update_pkg() {
	local out="$1"

	action "Updating package list"

	if ! apt-get update -qq -eany </dev/null 2>"$out" 1>&2; then
		failed
		error "Failed to update package list" "$out"
		exit 1
	fi

	success
}

install_pkg() {
	local out="$1"
	local s

	s=""

	if [[ "${#PKG_NAME[@]}" -gt 1 ]]; then
		s="s"
	fi

	action "Installing package${s} '${PKG_NAME[*]}'"

	if ! apt-get install -qq "${PKG_NAME[@]}" </dev/null 2>"$out" 1>&2; then
		failed
		error "Failed to install package${s} '${PKG_NAME[*]}'" "$out"
		exit 1
	fi

	success
}

################################################################################
# Repository Information:
################################################################################

declare -ar KEY_FING=("35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3")
declare -ar PKG_NAME=("google-cloud-cli")
REP_NAME="google-cloud"
KEY_LINK="https://packages.cloud.google.com/apt/doc/apt-key.gpg"
KEY_PATH="/etc/apt/keyrings/"
KEY_NAME=""
REP_LINK="https://packages.cloud.google.com/apt"
REP_PATH="/etc/apt/sources.list.d/$REP_NAME.sources"

readonly REP_NAME KEY_LINK KEY_PATH REP_LINK REP_PATH

################################################################################
# Main:
################################################################################

main() {
	local dir
	local out
	local key
	local inf
	local tmp

	dir=$(mktemp -d)
	out="$dir/out"
	key="$dir/key"
	inf="$dir/inf"
	tmp="$dir/tmp"

	trap 'rm -fr -- "$dir"' EXIT

	download_key "$out" "$key"
	validate_key "$out" "$key" "$inf"
	install_key "$out" "$key"
	install_repo "$out" "$tmp"
	update_pkg "$out"
	install_pkg "$out"

	rm -fr -- "$dir"
	trap - EXIT

	local s
	local be

	s=""
	be="has"

	if [[ "${#PKG_NAME[@]}" -gt 1 ]]; then
		s="s"
		be="have"
	fi

	exit_success "Package${s} '${PKG_NAME[*]}' ${be} been installed successfully."
}

main
