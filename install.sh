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
	local out_file="$1"
	local key_file="$2"
	local key_link="$3"

	action "Downloading key from $key_link"

	if ! curl -sfLSo "$key_file" "$key_link" 2>"$out_file"; then
		failed
		error "Failed to download key from $key_link" "$out_file"
		exit 1
	fi

	success
}

validate_key() {
	local out_file="$1"
	local key_file="$2"
	local inf_file="$3"
	local rep_name="$4"
	local -n key_fing="$5"

	action "Validating key for $rep_name"

	if ! gpg --batch --no-keyring --no-options --no-tty --trust-model always --show-keys --with-colons \
		"$key_file" </dev/null 2>"$out_file" >"$inf_file"; then
		failed
		error "Failed to validate key for $rep_name" "$out_file"
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
	done 2>"$out_file" <"$inf_file"; then
		failed
		error "Failed to read key information for $rep_name" "$out_file"
		exit 1
	fi

	if [[ "${#fingerprints[@]}" -eq 0 ]]; then
		failed
		error "No primary key fingerprints found for $rep_name" "$out_file"
		exit 1
	fi

	local found
	local allowed

	for found in "${fingerprints[@]}"; do
		local valid=false

		for allowed in "${key_fing[@]}"; do
			if [[ "$found" == "$allowed" ]]; then
				valid=true
				break
			fi
		done

		if [[ "$valid" == false ]]; then
			failed
			error "Untrusted primary key fingerprint found for $rep_name: $found" "$out_file"
			exit 1
		fi
	done

	success
}

install_key() {
	local out_file="$1"
	local key_file="$2"
	local rep_name="$3"
	local key_path="$4"
	local -n key_ref="$5"
	local header

	action "Installing key for $rep_name"

	if ! IFS= read -rN 36 header 2>"$out_file" <"$key_file"; then
		failed
		error "Failed to inspect key format for $rep_name" "$out_file"
		exit 1
	fi

	if [[ "$header" == "-----BEGIN PGP PUBLIC KEY BLOCK-----" ]]; then
		key_ref="$key_path$rep_name.asc"
	else
		key_ref="$key_path$rep_name.gpg"
	fi

	if ! install -Dm 0644 "$key_file" "$key_ref" 2>"$out_file"; then
		failed
		error "Failed to install key for $rep_name" "$out_file"
		exit 1
	fi

	success
}

install_repo() {
	local out_file="$1"
	local tmp_file="$2"
	local rep_name="$3"
	local rep_link="$4"
	local rep_path="$5"
	local -n key_ref="$6"
	local info

	local -a rep_lines=(
		"Types: deb"
		"URIs: $rep_link"
		"Suites: cloud-sdk"
		"Components: main"
		"Signed-By: $key_ref"
	)

	printf -v info "%s\n" "${rep_lines[@]}"

	action "Installing repository for $rep_name"

	if ! printf "%s" "$info" 2>"$out_file" >"$tmp_file"; then
		failed
		error "Failed to prepare repository for $rep_name" "$out_file"
		exit 1
	fi

	if ! install -Dm 0644 "$tmp_file" "$rep_path" 2>"$out_file"; then
		failed
		error "Failed to install repository for $rep_name" "$out_file"
		exit 1
	fi

	success
}

update_pkg() {
	local out_file="$1"

	action "Updating package list"

	if ! apt-get update -qq -eany </dev/null 2>"$out_file" 1>&2; then
		failed
		error "Failed to update package list" "$out_file"
		exit 1
	fi

	success
}

install_pkg() {
	local out_file="$1"
	local -n pkg_name="$2"
	local s

	s=""

	if [[ "${#pkg_name[@]}" -gt 1 ]]; then
		s="s"
	fi

	action "Installing package${s} '${pkg_name[*]}'"

	if ! apt-get install -qq "${pkg_name[@]}" </dev/null 2>"$out_file" 1>&2; then
		failed
		error "Failed to install package${s} '${pkg_name[*]}'" "$out_file"
		exit 1
	fi

	success
}

################################################################################
# Repository Information:
################################################################################

# shellcheck disable=SC2034
declare -ar KEY_FING=("35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3")
# shellcheck disable=SC2034
declare -ar PKG_NAME=("google-cloud-cli")
REP_NAME="google-cloud"
KEY_LINK="https://packages.cloud.google.com/apt/doc/apt-key.gpg"
KEY_PATH="/etc/apt/keyrings/"
REP_LINK="https://packages.cloud.google.com/apt"
REP_PATH="/etc/apt/sources.list.d/$REP_NAME.sources"

readonly REP_NAME KEY_LINK KEY_PATH REP_LINK REP_PATH

################################################################################
# Main:
################################################################################

main() {
	local dir
	local key
	local inf
	local out
	local tmp
	local key_name

	dir=$(mktemp -d)
	key="$dir/key"
	inf="$dir/inf"
	out="$dir/out"
	tmp="$dir/tmp"
	# shellcheck disable=SC2034
	key_name=""

	trap 'rm -fr -- "$dir"' EXIT

	download_key "$out" "$key" "$KEY_LINK"
	validate_key "$out" "$key" "$inf" "$REP_NAME" KEY_FING
	install_key "$out" "$key" "$REP_NAME" "$KEY_PATH" key_name
	install_repo "$out" "$tmp" "$REP_NAME" "$REP_LINK" "$REP_PATH" key_name
	update_pkg "$out"
	install_pkg "$out" PKG_NAME

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
