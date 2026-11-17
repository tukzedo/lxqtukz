#!/usr/bin/env bash

#  shellcheck disable=2155  ## 'Declare and assign separately to avoid masking return values.' Cumbersome and unnecessary.

##	- Purpose: Installer and updater for LXQtukz. Run from the web it installs;
##	  installed, it is /usr/local/bin/lxqtukz-update and keeps the desktop
##	  current. One script, so installing and updating can never disagree.
##	- Every release stays addressable: --to takes any published version, older
##	  or newer, and --list shows them all.
##	- Debian: each version unpacks to /opt/lxqtukz/versions/<version>, and the
##	  'current' symlink picks the active one. Switching is one atomic rename,
##	  rollback is instant while the old version is still on disk, and a running
##	  session keeps the version it logged in with until the next login.
##	- NixOS: the system flake's 'lxqtukz' input is re-locked to the release tag
##	  and the system rebuilt (see the module's services.lxqtukz options).
##	- Settings: /etc/xdg/lxqtukz/update.conf (AUTO_UPDATE, CHANNEL, PIN, KEEP).
##	- Syntax:
##	  bash <(curl -fsSL https://raw.githubusercontent.com/tukzedo/lxqtukz/main/install.bash) [options]
##	  lxqtukz-update [options]
##	    (no options)            install, or update to the newest release on the channel
##	    --to VERSION            install and switch to exactly this version
##	    --channel stable|dev    stable: full releases only; dev: pre-releases too
##	    --list                  published releases, marking installed and active
##	    --status                what is active, installed, and configured
##	    --rollback              switch back to the version active before this one
##	    --auto                  what the daily timer runs; honors update.conf
##	    --from PATH             install a local release archive (Debian)
##	    --uninstall             remove LXQtukz (settings are kept)
##	    -y, --yes               don't ask before making changes
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

REPO="tukzedo/lxqtukz"
ROOT="/opt/lxqtukz"
STATE_DIR="/var/lib/lxqtukz"
HISTORY_FILE="${STATE_DIR}/history"
SYS_CONF_DIR="/etc/xdg/lxqtukz"
POLKIT_DIR="/usr/share/polkit-1/actions"


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Output helpers

## Inline rather than sourced: run as `bash <(curl ...)` there is nothing
## beside this script to source.
_wasLastEchoBlank=0
fEcho_Clean(){ if [[ -n "${1:-}" ]]; then echo "$*"; _wasLastEchoBlank=0; elif [[ $_wasLastEchoBlank -eq 0 ]] && echo; then _wasLastEchoBlank=1; fi; }
fEcho(){       if [[ -n "$*" ]]; then fEcho_Clean "[ $* ]"; else fEcho_Clean ""; fi; }
fWarn(){ fEcho_Clean "WARNING: $*" >&2; }
fDie(){  { fEcho_Clean ""; fEcho_Clean "FAILED: $*"; fEcho_Clean ""; } >&2; exit 1; }

fAbort(){ printf "\nLXQTUKZ UPDATE ABORTED (exit %s) at line %s: %s\n\n" "$1" "$2" "$3" >&2; exit "$1"; }
trap 'fAbort $? $LINENO "$BASH_COMMAND"' ERR

fHelp(){
	cat <<-EOF

		LXQtukz installer and updater.

		  bash <(curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.bash) [options]
		  lxqtukz-update [options]

		    (no options)            install, or update to the newest release on the channel
		    --to VERSION            install and switch to exactly this version (older or newer)
		    --channel stable|dev    stable: full releases only; dev: pre-releases too
		    --list                  published releases, marking installed and active
		    --status                what is active, installed, and configured
		    --rollback              switch back to the version active before this one
		    --auto                  what the daily timer runs; honors update.conf
		    --from PATH             install a local release archive (Debian)
		    --uninstall             remove LXQtukz (settings are kept)
		    -y, --yes               don't ask before making changes
		    -h, --help              this text

		  Settings: ${SYS_CONF_DIR}/update.conf
		  Debian: versions live in ${ROOT}/versions/, the active one is ${ROOT}/current.
		  NixOS:  re-locks the 'lxqtukz' input of the system flake and rebuilds.

	EOF
}


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Arguments

action="update"; toVersion=""; channelArg=""; from=""; declare -i assumeYes=0
while (($#)); do case "$1" in
	--to)        toVersion="${2:-}"; action="update"; shift 2 ;;
	--channel)   channelArg="${2:-}"; shift 2 ;;
	--list)      action="list"; shift ;;
	--status)    action="status"; shift ;;
	--rollback)  action="rollback"; shift ;;
	--auto)      action="auto"; assumeYes=1; shift ;;
	--from)      from="${2:-}"; shift 2 ;;
	--uninstall) action="uninstall"; shift ;;
	-y|--yes)    assumeYes=1; shift ;;
	-h|--help)   fHelp; exit 0 ;;
	*) fDie "unknown option: $1 (try --help)" ;;
esac; done
toVersion="${toVersion#v}"


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Platform

if [[ -e /etc/NIXOS ]]; then
	platform="nixos"
elif [[ -r /etc/os-release ]] && (. /etc/os-release; [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]]); then
	platform="debian13"
else
	platform="unsupported"
fi
case "$(uname -m)" in
	x86_64|amd64)  arch="x86_64" ;;
	aarch64|arm64) arch="arm64" ;;
	*) arch="$(uname -m)" ;;
esac
target="${platform}-${arch}"

SUDO=""; ((EUID == 0)) || SUDO="sudo"

## update.conf is KEY=value, read here rather than sourced, so a bad line in
## it can't run anything as root. Admin's copy first, then the release's.
fConf(){ ## key default
	local file value
	for file in "${SYS_CONF_DIR}/update.conf" "${ROOT}/current/etc/xdg/lxqtukz/update.conf"; do
		[[ -r "${file}" ]] || continue
		value="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "${file}" | tail -1 | sed 's/[[:space:]]*$//')"
		if grep -q "^[[:space:]]*$1[[:space:]]*=" "${file}"; then
			echo "${value:-$2}"; return 0
		fi
	done
	echo "$2"
}

channel="${channelArg:-$(fConf CHANNEL stable)}"
[[ "${channel}" == "stable" || "${channel}" == "dev" ]] || fDie "channel must be stable or dev, not '${channel}'"


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Releases

## Published releases, newest first: "<version> <stable|dev>". Read from the
## GitHub API without jq: tag_name always comes before prerelease in a release.
fReleases(){
	local json
	json="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=100" 2>/dev/null)" || { fWarn "can't read releases from github.com/${REPO}"; return 0; }
	echo "${json}" | awk -F'"' '
			/"tag_name":/   { tag = $4 }
			/"prerelease":/ { if (tag != "") { sub(/^v/, "", tag); print tag, ($0 ~ /true/ ? "dev" : "stable"); tag = "" } }
		'
}

fNewestOnChannel(){
	local releases="$1"
	if [[ "${channel}" == "dev" ]]; then
		echo "${releases}" | awk 'NF {print $1}' | head -1
	else
		echo "${releases}" | awk '$2 == "stable" {print $1}' | head -1
	fi
}

fAssetUrl(){ echo "https://github.com/${REPO}/releases/download/v$1/$2"; }


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# State

fActiveVersion(){
	if [[ "${platform}" == "nixos" ]]; then
		sed -n 's/^LXQTUKZ_VERSION=//p' "${SYS_CONF_DIR}/manifest" 2>/dev/null || true
	elif [[ -L "${ROOT}/current" ]]; then
		basename "$(readlink "${ROOT}/current")"
	fi
}

fInstalledVersions(){
	[[ "${platform}" != "nixos" && -d "${ROOT}/versions" ]] || return 0
	local dir
	for dir in "${ROOT}/versions"/*/; do
		[[ -f "${dir}.complete" ]] && basename "${dir}"
	done | sort -rV
}

## The version that was active before the current one, from the switch history.
fPreviousVersion(){
	[[ -r "${HISTORY_FILE}" ]] || return 0
	awk -v cur="$(fActiveVersion)" '{ for (i = 2; i <= NF; i++) if ($i ~ /^from=/) { v = substr($i, 6); if (v != "none" && v != cur) prev = v } } END { print prev }' "${HISTORY_FILE}"
}

fRecordSwitch(){ ## from to reason
	${SUDO} mkdir -p "${STATE_DIR}"
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) from=${1:-none} to=$2 by=$3" | ${SUDO} tee -a "${HISTORY_FILE}" >/dev/null
}

fConfirm(){
	((assumeYes)) && return 0
	[[ -t 0 ]] || fDie "not a terminal; re-run with -y to proceed"
	local answer; read -r -p "Proceed? [y/N] " answer
	[[ "${answer}" == [yY]* ]] || { fEcho "nothing changed"; exit 0; }
}


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Debian

## Running processes mapping files from a version dir means a session is on it.
fVersionInUse(){
	${SUDO} sh -c "grep -qs '${ROOT}/versions/$1/' /proc/[0-9]*/maps"
}

fFetchVersion(){ ## version -> unpacked and marked complete
	local version="$1" dest="${ROOT}/versions/$1" tmp base archive deps
	[[ -f "${dest}/.complete" ]] && return 0
	tmp="$(mktemp -d)"; base="lxqtukz-${version}-${target}"
	if [[ -n "${from}" ]]; then
		cp "${from}" "${tmp}/${base}.tar.gz"
		if [[ -f "${from%.tar.gz}-deps.txt" ]]; then cp "${from%.tar.gz}-deps.txt" "${tmp}/${base}-deps.txt"; fi
		fWarn "installing from ${from}: no published checksum to verify against"
	else
		fEcho "download ${base}"
		curl -fL --progress-bar -o "${tmp}/${base}.tar.gz" "$(fAssetUrl "${version}" "${base}.tar.gz")" \
			|| fDie "release ${version} has no build for ${target}"
		curl -fsSL -o "${tmp}/${base}-deps.txt" "$(fAssetUrl "${version}" "${base}-deps.txt")"
		curl -fsSL -o "${tmp}/sums" "$(fAssetUrl "${version}" "lxqtukz-${version}-sha256sums.txt")"
		( cd "${tmp}" && grep -E " (${base}\.tar\.gz|${base}-deps\.txt)\$" sums | sha256sum -c --quiet - ) \
			|| fDie "checksum mismatch for ${base}; not installing it"
	fi
	archive="${tmp}/${base}.tar.gz"; deps="${tmp}/${base}-deps.txt"
	[[ "$(tar -tzf "${archive}" | head -1 | cut -d/ -f1)" == "${version}" ]] || fDie "${archive} is not an LXQtukz ${version} archive"

	if [[ -s "${deps}" ]]; then
		local package; local -a missing=()
		while read -r package; do
			[[ -n "${package}" ]] || continue
			[[ "$(dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null || true)" == "installed" ]] || missing+=("${package}")
		done < "${deps}"
		if ((${#missing[@]})); then
			fEcho "apt install ${missing[*]}"
			${SUDO} apt-get update -qq
			${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
		fi
	else
		fWarn "no dependency list; runtime packages were not checked"
	fi

	## Unpacked beside its final place and renamed in, so a half-written
	## version dir never exists under its real name.
	${SUDO} mkdir -p "${ROOT}/versions"
	${SUDO} rm -rf "${ROOT}/versions/.incoming-${version}"
	${SUDO} mkdir -p "${ROOT}/versions/.incoming-${version}"
	${SUDO} tar -xzf "${archive}" -C "${ROOT}/versions/.incoming-${version}" --no-same-owner
	${SUDO} touch "${ROOT}/versions/.incoming-${version}/${version}/.complete"
	${SUDO} rm -rf "${dest}"
	${SUDO} mv "${ROOT}/versions/.incoming-${version}/${version}" "${dest}"
	${SUDO} rmdir "${ROOT}/versions/.incoming-${version}"
	rm -rf "${tmp}"
}

fActivate(){ ## version reason
	local previous="$(fActiveVersion)"
	[[ "${previous}" != "$1" ]] || return 0
	${SUDO} ln -sfn "versions/$1" "${ROOT}/.current-new"
	${SUDO} mv -T "${ROOT}/.current-new" "${ROOT}/current"
	fRecordSwitch "${previous}" "$1" "$2"
	fEcho "active: $1 (was ${previous:-none}); takes effect at next login"
}

## Puts the active version where the system looks for it. Idempotent, and
## re-run on every switch, since a new version may have new files.
fIntegrate(){
	local cur="${ROOT}/current" unit
	${SUDO} mkdir -p /usr/share/wayland-sessions /usr/local/bin "${SYS_CONF_DIR}"
	${SUDO} ln -sfn "${cur}/share/wayland-sessions/lxqtukz.desktop" /usr/share/wayland-sessions/lxqtukz.desktop
	${SUDO} ln -sfn "${cur}/bin/lxqtukz-update" /usr/local/bin/lxqtukz-update
	if [[ ! -e "${SYS_CONF_DIR}/update.conf" ]]; then
		${SUDO} cp "${cur}/etc/xdg/lxqtukz/update.conf" "${SYS_CONF_DIR}/update.conf"
	fi
	if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
		## disable also removes a linked unit's own link, which would leave
		## nothing to enable later. So it goes before the links are made.
		if [[ "$(fConf AUTO_UPDATE yes)" == "no" ]]; then
			${SUDO} systemctl disable --now lxqtukz-update.timer >/dev/null 2>&1 || true
		fi
		for unit in lxqtukz-update.service lxqtukz-update.timer; do
			${SUDO} ln -sfn "${cur}/lib/systemd/system/${unit}" "/etc/systemd/system/${unit}"
		done
		${SUDO} systemctl daemon-reload
		if [[ "$(fConf AUTO_UPDATE yes)" != "no" ]]; then
			${SUDO} systemctl enable --now lxqtukz-update.timer >/dev/null 2>&1
		fi
	fi
	fPolkitLink
}

## polkit reads actions from its own dirs only. polkitd misses links in one
## made after it started, such as /usr/local's, so they go in the one it
## always has. Each version's action names that version's backlight
## helper, and a session keeps the version it logged in with, so every
## installed version gets a link. Builds from before the rename have the
## distro's own file name, which is never linked.
fPolkitLink(){
	local file dest
	${SUDO} mkdir -p "${POLKIT_DIR}"
	for file in "${ROOT}"/versions/*/share/polkit-1/actions/org.lxqtukz.*.policy; do
		dest="${POLKIT_DIR}/${file##*/}"
		[[ -f "${file}" && ( -L "${dest}" || ! -e "${dest}" ) ]] || continue
		${SUDO} ln -sfn "${file}" "${dest}"
	done
	fPolkitUnlink stale
}

## Our links in POLKIT_DIR: all of them, or with 'stale' those whose version is gone.
fPolkitUnlink(){ ## [stale]
	local link
	for link in "${POLKIT_DIR}"/*.policy; do
		[[ -L "${link}" && "$(readlink "${link}")" == "${ROOT}/"* ]] || continue
		[[ "${1:-}" == stale && -e "${link}" ]] && continue
		${SUDO} rm -f "${link}"
	done
	return 0
}

## Keeps KEEP versions, newest first, and always keeps the active one, the
## rollback target, and any a running session is still using.
fPrune(){
	local keep="$(fConf KEEP 3)" active="$(fActiveVersion)" previous="$(fPreviousVersion)" version
	[[ "${keep}" =~ ^[0-9]+$ ]] && ((keep >= 1)) || keep=3
	local -i kept=0
	while read -r version; do
		[[ -n "${version}" ]] || continue
		if [[ "${version}" == "${active}" || "${version}" == "${previous}" ]] || ((kept < keep)); then
			kept+=1; continue
		fi
		if fVersionInUse "${version}"; then fEcho "keeping ${version}: a running session uses it"; continue; fi
		fEcho "remove ${version}"
		${SUDO} rm -rf "${ROOT:?}/versions/${version}"
	done < <(fInstalledVersions)
}

fDebianSwitch(){ ## version reason
	fFetchVersion "$1"
	fActivate "$1" "$2"
	fPrune
	fIntegrate
}

fDebianUninstall(){
	fEcho_Clean "This removes ${ROOT}, the session entry, the updater and its timer, and the backlight helper's polkit action."
	fEcho_Clean "Kept: ${SYS_CONF_DIR}/, every user's ~/.config/lxqtukz/, and packages apt installed."
	fConfirm
	if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
		${SUDO} systemctl disable --now lxqtukz-update.timer >/dev/null 2>&1 || true
		${SUDO} rm -f /etc/systemd/system/lxqtukz-update.service /etc/systemd/system/lxqtukz-update.timer
		${SUDO} systemctl daemon-reload
	fi
	${SUDO} rm -f /usr/share/wayland-sessions/lxqtukz.desktop /usr/local/bin/lxqtukz-update
	fPolkitUnlink
	${SUDO} rm -rf "${ROOT}" "${STATE_DIR}"
	fEcho "LXQtukz removed"
}


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# NixOS

fNixosSwitch(){ ## version reason
	local flake="$(fConf FLAKE /etc/nixos)" rebuild="$(fConf NIXOS_REBUILD boot)" previous="$(fActiveVersion)"
	[[ "${rebuild}" == "boot" || "${rebuild}" == "switch" ]] || fDie "NIXOS_REBUILD must be boot or switch"
	[[ -f "${flake}/flake.nix" ]] || fDie "no flake at ${flake}; LXQtukz on NixOS is installed as a flake input (see README)"
	grep -q 'lxqtukz' "${flake}/flake.nix" || fDie "${flake}/flake.nix has no 'lxqtukz' input (see README)"
	[[ -z "${from}" ]] || fDie "--from is Debian only; on NixOS point the flake input at a path instead"
	fEcho "lock lxqtukz input to v$1 in ${flake}"
	${SUDO} nix --extra-experimental-features 'nix-command flakes' flake lock "${flake}" \
		--override-input lxqtukz "github:${REPO}/v$1"
	fEcho "nixos-rebuild ${rebuild}"
	${SUDO} nixos-rebuild "${rebuild}" --flake "${flake}"
	fRecordSwitch "${previous}" "$1" "$2"
}


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Actions

fSwitch(){ ## version reason
	case "${platform}" in
		nixos)    fNixosSwitch  "$1" "$2" ;;
		debian13) fDebianSwitch "$1" "$2" ;;
		*) fDie "unsupported system; LXQtukz installs on Debian 13 and NixOS for now" ;;
	esac
}

fList(){
	local releases="$(fReleases)" installed="$(fInstalledVersions)" active="$(fActiveVersion)" version kind marks
	[[ -n "${releases}" ]] || fDie "no releases found at github.com/${REPO}"
	while read -r version kind; do
		marks=""
		grep -qxF "${version}" <<<"${installed}" && marks+=" installed"
		[[ "${version}" == "${active}" ]] && marks+=" ACTIVE"
		printf "  %-20s %-7s%s\n" "${version}" "${kind}" "${marks}"
	done <<<"${releases}"
}

fStatus(){
	fEcho_Clean "platform:     ${target}"
	fEcho_Clean "active:       $(fActiveVersion || true)"
	[[ "${platform}" == "nixos" ]] || fEcho_Clean "installed:    $(fInstalledVersions | tr '\n' ' ')"
	fEcho_Clean "rollback to:  $(fPreviousVersion)"
	fEcho_Clean "channel:      ${channel}"
	fEcho_Clean "pin:          $(fConf PIN '')"
	fEcho_Clean "auto update:  $(fConf AUTO_UPDATE yes)"
	[[ -r "${HISTORY_FILE}" ]] && { fEcho_Clean "recent switches:"; tail -5 "${HISTORY_FILE}" | sed 's/^/  /'; }
	return 0
}

fUpdate(){ ## reason
	local active="$(fActiveVersion)" wanted="${toVersion}" releases
	if [[ -n "${from}" ]]; then
		[[ "${platform}" != "nixos" ]] || fDie "--from is Debian only"
		[[ -f "${from}" ]] || fDie "no such file: ${from}"
		wanted="$(tar -tzf "${from}" 2>/dev/null | head -1 | cut -d/ -f1 || true)"
		[[ -n "${wanted}" ]] || fDie "can't read a version out of ${from}"
	else
		releases="$(fReleases)"
		[[ -n "${releases}" ]] || fDie "no releases found at github.com/${REPO}"
		[[ -n "${wanted}" ]] || wanted="$(fConf PIN '')"; wanted="${wanted#v}"
		[[ -n "${wanted}" ]] || wanted="$(fNewestOnChannel "${releases}")"
		[[ -n "${wanted}" ]] || fDie "no ${channel} release yet (try --channel dev)"
		awk '{print $1}' <<<"${releases}" | grep -qxF "${wanted}" || fDie "no published release ${wanted} (see --list)"
	fi
	if [[ "${wanted}" == "${active}" ]]; then fEcho "already on ${active}"; return 0; fi
	fEcho_Clean "LXQtukz: ${active:-not installed} -> ${wanted} (${target})"
	fConfirm
	fSwitch "${wanted}" "$1"
}

case "${action}" in
	list)      fList ;;
	status)    fStatus ;;
	update)    fUpdate "manual" ;;
	auto)
		[[ "$(fConf AUTO_UPDATE yes)" != "no" ]] || exit 0
		fUpdate "auto" ;;
	rollback)
		previous="$(fPreviousVersion)"
		[[ -n "${previous}" ]] || fDie "nothing to roll back to"
		toVersion="${previous}"
		fEcho_Clean "Roll back: $(fActiveVersion) -> ${previous}"
		fConfirm
		fSwitch "${previous}" "rollback" ;;
	uninstall)
		[[ "${platform}" != "nixos" ]] || fDie "on NixOS, remove services.lxqtukz from the system config instead"
		fDebianUninstall ;;
esac


##	History:
##		- 2026-10-12: Created.
##		- 2026-10-15: Links the backlight helper's polkit action; AUTO_UPDATE=no
##		  keeps the timer's unit link.
