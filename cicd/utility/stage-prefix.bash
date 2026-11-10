#!/usr/bin/env bash

##	- Purpose: Finishes a prefix that already has every built component:
##	  adds LXQtukz's own files, builds the vendor settings dir, and writes the
##	  release manifest. The Debian build and the Nix package both call this, so
##	  the two install layouts can't drift apart.
##	- Vendor settings, <prefix>/etc/xdg/lxqtukz/, are built in layers:
##	    1. upstream LXQt defaults (<prefix>/share/lxqt/*.conf, and
##	       <prefix>/etc/xdg/lxqt/*.conf, where lxqt-panel puts panel.conf)
##	    2. upstream's Wayfire config for LXQt, as wayfire.ini
##	    3. our own files from source/etc/xdg/lxqtukz/, which win
##	  Changing a default is therefore either a patch to the upstream file (for
##	  a change worth offering upstream) or a file in source/ (for ours alone).
##	- Syntax: stage-prefix.bash PREFIX EXEC_PREFIX VERSION COMMIT TARGET
##	    PREFIX       the directory to finish (writable)
##	    EXEC_PREFIX  the path the session file should launch from at run time
##	                 (Debian: /opt/lxqtukz/current; Nix: the store path)
##	    VERSION      LXQtukz version
##	    COMMIT       LXQtukz git commit, or 'unknown'
##	    TARGET       build target label, e.g. debian13-x86_64 or nixos
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=include/echo.bash
source "${REPO_ROOT}/cicd/utility/include/echo.bash"
# shellcheck source=include/components.bash
source "${REPO_ROOT}/cicd/utility/include/components.bash"

(($# == 5)) || fDie "usage: stage-prefix.bash PREFIX EXEC_PREFIX VERSION COMMIT TARGET"
prefix="$1"; execPrefix="$2"; version="$3"; commit="$4"; target="$5"
[[ -d "${prefix}" ]] || fDie "no such prefix: ${prefix}"
src="${REPO_ROOT}/source"

## On Nix the prefix is a symlink farm; replace a link before writing through it.
fPlace(){ ## mode source dest
	mkdir -p "$(dirname "$3")"; rm -f "$3"; install -m "$1" "$2" "$3"
}


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Our own files

fPlace 0755 "${src}/bin/startlxqtukz"  "${prefix}/bin/startlxqtukz"
fPlace 0755 "${src}/bin/lxqtukz-lock"  "${prefix}/bin/lxqtukz-lock"
## The installer is the updater; one script, so the two can't disagree.
fPlace 0755 "${REPO_ROOT}/install.bash" "${prefix}/bin/lxqtukz-update"
for unit in "${src}"/lib/systemd/system/*; do
	fPlace 0644 "${unit}" "${prefix}/lib/systemd/system/$(basename "${unit}")"
done
for entry in "${src}"/share/applications/*.desktop; do
	fPlace 0644 "${entry}" "${prefix}/share/applications/$(basename "${entry}")"
done

## liblxqt's backlight action has the same file name and id as a distro
## LXQt's, so linked in beside it, one would hide the other. Each version
## gets its own, since each names its own helper path.
actions="${prefix}/share/polkit-1/actions"
upstreamAction="${actions}/org.lxqt.backlight.pkexec.policy"
ourAction="org.lxqtukz.backlight-${version}"
if [[ -e "${upstreamAction}" ]]; then
	grep -q 'id="org.lxqt.backlight.pkexec"' "${upstreamAction}" || fDie "${upstreamAction} has no org.lxqt.backlight.pkexec action"
	sed "s|id=\"org.lxqt.backlight.pkexec\"|id=\"${ourAction}\"|" "${upstreamAction}" > "${actions}/.${ourAction}.policy"
	rm -f "${upstreamAction}" "${actions}/${ourAction}.policy"
	mv "${actions}/.${ourAction}.policy" "${actions}/${ourAction}.policy"
fi
[[ -f "${actions}/${ourAction}.policy" ]] || fDie "missing ${actions}/${ourAction}.policy; was liblxqt built?"

sessionFile="${prefix}/share/wayland-sessions/lxqtukz.desktop"
mkdir -p "$(dirname "${sessionFile}")"; rm -f "${sessionFile}"
sed "s|@EXEC_PREFIX@|${execPrefix}|g" "${src}/share/wayland-sessions/lxqtukz.desktop" > "${sessionFile}"


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Vendor settings

vendor="${prefix}/etc/xdg/lxqtukz"
## Rebuilt from scratch each time, so a removed default goes away.
rm -rf "${vendor}"; mkdir -p "${vendor}"
## LXQT_CONFIG_NAME moves every module's settings dir to lxqtukz/, so a
## default left in etc/xdg/lxqt/ is never read. The panel came up empty that way.
for conf in "${prefix}"/share/lxqt/*.conf "${prefix}"/etc/xdg/lxqt/*.conf; do
	[[ -e "${conf}" ]] || continue
	cp -L --no-preserve=mode "${conf}" "${vendor}/"
done
[[ -f "${vendor}/panel.conf" ]] || fDie "no panel.conf for ${vendor}; the panel would start empty"
upstreamWayfire="${prefix}/share/lxqt/wayland/lxqt-wayfire.ini"
[[ -f "${upstreamWayfire}" ]] || fDie "missing ${upstreamWayfire}; was lxqt-wayland-session built?"
cp -L --no-preserve=mode "${upstreamWayfire}" "${vendor}/wayfire.ini"
## Upstream's file starts things from LXQt under /usr, such as the wallpaper.
## Wayfire runs those lines through sh, and startlxqtukz exports
## LXQTUKZ_PREFIX, so the user's copy follows whichever version is running.
# shellcheck disable=2016  ## Expanded later, by the shell Wayfire starts.
sed -i 's|/usr/share/lxqt/|${LXQTUKZ_PREFIX}/share/lxqt/|g' "${vendor}/wayfire.ini"
## lxqt-session starts the portal as Qt starts up, before it hands D-Bus the
## session's environment, so the portal's LXQt backend found no display, died,
## and the session went without it. Hand the display over first.
grep -q '^session[[:space:]]*=[[:space:]]*lxqt-session' "${vendor}/wayfire.ini" \
	|| fDie "wayfire.ini has no 'session = lxqt-session' line to start the display hand-over from"
sed -i 's|^session\([[:space:]]*\)=[[:space:]]*lxqt-session|session\1= dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY; lxqt-session|' "${vendor}/wayfire.ini"
wayfireActive="$(awk '!/^[[:space:]]*#/' "${vendor}/wayfire.ini")"
## A /usr path is fine for what Debian has, and wrong for what the prefix has.
while read -r used; do
	[[ -z "${used}" || ! -e "${prefix}/${used}" ]] || fDie "wayfire.ini uses /usr/${used}, which the prefix has"
done < <(grep -oE '/usr/[^[:space:]"'\'']+' <<< "${wayfireActive}" | sed 's|^/usr/||' || true)
# shellcheck disable=2016  ## The variable name is the text being matched.
while read -r used; do
	[[ -z "${used}" || -e "${prefix}/${used}" ]] || fDie "wayfire.ini uses ${used}, which is not in the prefix"
done < <(grep -oE '\$\{LXQTUKZ_PREFIX\}/[^[:space:]"'\'']+' <<< "${wayfireActive}" | sed 's|^\${LXQTUKZ_PREFIX}/||' || true)
cp -RL --no-preserve=mode "${src}/etc/xdg/lxqtukz/." "${vendor}/"
## Wayfire only logs a plugin it can't load, and that plugin's bindings do
## nothing. So every plugin listed has to be in the prefix.
plugins="$(awk '
	/^\[/ { core = ($0 == "[core]"); next }
	core && !more && /^plugins[[:space:]]*=/ { sub(/^[^=]*=/, ""); more = 1 }
	more { line = $0; cont = sub(/\\[[:space:]]*$/, "", line); out = out " " line; if (!cont) exit }
	END { print out }' "${vendor}/wayfire.ini")"
[[ -n "${plugins// /}" ]] || fDie "wayfire.ini has no [core] plugins list"
for plugin in ${plugins}; do
	[[ -f "${prefix}/lib/wayfire/lib${plugin}.so" ]] || fDie "wayfire.ini loads the ${plugin} plugin, which the prefix doesn't have"
done

fGeneral_Set(){ ## file key value
	if grep -q "^$2[[:space:]]*=" "$1"; then
		sed -i "s|^$2[[:space:]]*=.*|$2=$3|" "$1"
	else
		sed -i "0,/^\\[General\\]/s||[General]\\n$2=$3|" "$1"
	fi
}
[[ -f "${vendor}/session.conf" ]] || fDie "missing ${vendor}/session.conf; was lxqt-session built?"
## Only Wayfire is offered, so upstream's compositor chooser has nothing to choose.
fGeneral_Set "${vendor}/session.conf" compositor wayfire
## Upstream leaves LXQt's Wayland lock command empty, and then nothing locks.
fGeneral_Set "${vendor}/session.conf" lock_command_wayland lxqtukz-lock
grep -q '^lock_command_wayland=lxqtukz-lock$' "${vendor}/session.conf" || fDie "session.conf has no [General] section for the lock command"


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Manifest

## What exactly this release is: enough to rebuild it, and what the updater
## and bug reports read back.
fComponents_Load
manifest="${prefix}/share/lxqtukz/manifest"
mkdir -p "$(dirname "${manifest}")"; rm -f "${manifest}"
{
	echo "LXQTUKZ_VERSION=${version}"
	echo "LXQTUKZ_COMMIT=${commit}"
	echo "LXQTUKZ_TARGET=${target}"
	echo "## component ref commit patches"
	for name in "${componentNames[@]}"; do
		## Debian-only rows are nixpkgs' own on NixOS.
		[[ "${target}" != nixos || "${componentNix[${name}]}" != - ]] || continue
		echo "COMPONENT ${name} ${componentRef[${name}]} ${componentCommit[${name}]} $(fComponents_Patches "${name}" | grep -c . || true)"
	done
} > "${manifest}"

fEcho "staged ${prefix} (${version}, ${target})"


##	History:
##		- 2026-10-12: Created.
##		- 2026-10-14: wayfire.ini paths under /usr point at the prefix.
##		- 2026-10-15: gtklock is the screen locker.
##		- 2026-10-15: The backlight action gets its own name per version;
##		  every plugin wayfire.ini lists must be in the prefix.
##		- 2026-11-10: Defaults from etc/xdg/lxqt too, for the panel.
