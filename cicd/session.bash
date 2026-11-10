#!/usr/bin/env bash

#  shellcheck disable=2155  ## 'Declare and assign separately to avoid masking return values.' Cumbersome and unnecessary.

##	- Purpose: Starts the release build's session the way a display manager
##	  would, on a headless Wayfire with its own session bus, in the test
##	  container unless --here is given. Then checks that what the session
##	  starts comes from the prefix, not /usr:
##	    - the wallpaper Wayfire's [autostart] hands to swaybg
##	    - D-Bus started services, through the bus's runtime service dir
##	    - xdg-desktop-portal finding our portal and its config
##	    - the lock key and the idle lock: gtklock locks the session, with the
##	      user name module, and shows "Login failed" for a wrong password
##	- And that the manifest names the commit, Wayfire loads every plugin in
##	  its list, no key is bound twice, nothing starts pcmanfm-qt, and Super+E
##	  opens the home folder in the default file manager.
##	- The release comes from cicd/artifacts/release/, extracted to the path it
##	  was built for.
##	- Syntax: cicd/session.bash [--here]
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=utility/include/echo.bash
source "${REPO_ROOT}/cicd/utility/include/echo.bash"

fAbort(){ printf "\nSESSION ABORTED (exit %s) at line %s: %s\n\n" "$1" "$2" "$3" >&2; exit "$1"; }
trap 'fAbort $? $LINENO "$BASH_COMMAND"' ERR

BUILD_IMAGE="lxqtukz-build-debian13"
TEST_IMAGE="lxqtukz-test-debian13"
TARGET="debian13-$(uname -m)"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/version")"
PREFIX="/opt/lxqtukz/versions/${VERSION}"
EXTRACTED="${REPO_ROOT}/work/test/prefix"
PORTAL="org.freedesktop.impl.portal.desktop.lxqt"
KEYS="${REPO_ROOT}/cicd/utility/wayfire-keys.py"
SHOTS="${REPO_ROOT}/cicd/artifacts/session"

declare -i here=0
while (($#)); do case "$1" in
	--here) here=1; shift ;;
	-h|--help) sed -n '/^##\t- Purpose/,/^##\tHistory/p' "${BASH_SOURCE[0]}" | sed 's/^##\t\{0,1\}//'; exit 0 ;;
	*) fDie "unknown argument: $1" ;;
esac; done


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Outside: hand off to the container

if ((! here)); then
	command -v docker >/dev/null || fDie "docker is required; or use --here on a box set up like cicd/linux/Dockerfile.test"
	fSection "Build images"
	docker build -q -t "${BUILD_IMAGE}" -f "${REPO_ROOT}/cicd/linux/Dockerfile" "${REPO_ROOT}/cicd/linux" >/dev/null
	docker build -q -t "${TEST_IMAGE}" -f "${REPO_ROOT}/cicd/linux/Dockerfile.test" "${REPO_ROOT}/cicd/linux" >/dev/null
	tarball="${REPO_ROOT}/cicd/artifacts/release/lxqtukz-${VERSION}-${TARGET}.tar.gz"
	[[ -f "${tarball}" ]] || fDie "no release build at ${tarball}; run cicd/build.bash"
	fSection "Extract ${tarball##*/}"
	if [[ -e "${EXTRACTED}" ]]; then
		[[ -O "${EXTRACTED}" ]] || fDie "${EXTRACTED} is not ours; remove it by hand"
		chmod -R u+w "${EXTRACTED}"; rm -rf "${EXTRACTED}"
	fi
	mkdir -p "${EXTRACTED}"
	tar -C "${EXTRACTED}" -xzf "${tarball}"
	gpu=()
	if [[ -e /dev/dri/renderD128 ]]; then
		gpu=(--device /dev/dri --group-add "$(stat -c %g /dev/dri/renderD128)")
	fi
	passwd="${REPO_ROOT}/work/test/passwd"
	mkdir -p "${passwd%/*}"
	{ echo "root:x:0:0:root:/root:/bin/bash"; echo "tester:x:$(id -u):$(id -g):tester:/tmp:/bin/bash"; } > "${passwd}"
	mkdir -p "${SHOTS}"
	docker run --rm -i \
		-v "${REPO_ROOT}:/src:ro" -w /src \
		-v "${SHOTS}:/src/cicd/artifacts/session" \
		-v "${passwd}:/etc/passwd:ro" \
		-v "${EXTRACTED}/${VERSION}:${PREFIX}:ro" \
		--user "$(id -u):$(id -g)" -e HOME=/tmp \
		"${gpu[@]+"${gpu[@]}"}" \
		"${TEST_IMAGE}" /src/cicd/session.bash --here
	exit 0
fi


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Inside

run="$(mktemp -d "/tmp/test_lxqtukz-session_$(date +%Y%m%d-%H%M%S%2N)_XXXX")"
export HOME="${run}/home" XDG_RUNTIME_DIR="${run}/runtime"
mkdir -p "${HOME}" "${XDG_RUNTIME_DIR}"; chmod 700 "${XDG_RUNTIME_DIR}"
unset XDG_DATA_DIRS XDG_CONFIG_DIRS XDG_CONFIG_HOME XDG_DATA_HOME DISPLAY WAYLAND_DISPLAY

busPid="" sessionPid="" lockPid=""
fStopAll(){
	## gtklock is detached from the session, so it's stopped on its own.
	[[ -z "${lockPid}" ]] || kill "${lockPid}" 2>/dev/null || true
	[[ -z "${sessionPid}" ]] || kill "${sessionPid}" 2>/dev/null || true
	[[ -z "${busPid}" ]] || kill "${busPid}" 2>/dev/null || true
}
trap fStopAll EXIT

declare -i failed=0
fCheck(){ ## label ok|fail [detail]
	if [[ "$2" == ok ]]; then fEcho "ok: $1"; else fEcho "FAIL: $1${3:+ (${3})}"; failed=$((failed + 1)); fi
}

## Waits up to 15 s for a command to succeed.
fWaitFor(){ ## command...
	local _
	for _ in $(seq 75); do "$@" && return 0; sleep 0.2; done
	return 1
}

## The bus a systemd login would have: started before the session, so it never
## saw the prefix.
fSection "Session bus"
busDir="${XDG_RUNTIME_DIR}/dbus-1/services"
mkdir -p "${busDir}"
## One left by an earlier login, and one that isn't ours.
printf '%s\n' "# lxqtukz" "[D-BUS Service]" "Name=org.lxqtukz.Stale" "Exec=/bin/false" > "${busDir}/org.lxqtukz.Stale.service"
printf '%s\n' "[D-BUS Service]" "Name=org.example.Other" "Exec=/bin/false" > "${busDir}/org.example.Other.service"
## A distro's own copy of our portal, as Debian's LXQt has in /usr/share. The
## bus reads it at start, and on its own never takes ours over it.
distroDir="${run}/distro/dbus-1/services"
mkdir -p "${distroDir}"
printf '%s\n' "[D-BUS Service]" "Name=${PORTAL}" "Exec=/bin/false" > "${distroDir}/${PORTAL}.service"
XDG_DATA_DIRS="${run}/distro:/usr/local/share:/usr/share" \
	dbus-daemon --session --nofork --print-address=3 3> "${run}/bus.address" > "${run}/bus.log" 2>&1 &
busPid=$!
fWaitFor test -s "${run}/bus.address" || fDie "dbus-daemon did not start"
export DBUS_SESSION_BUS_ADDRESS="$(head -n1 "${run}/bus.address")"
fEcho "${DBUS_SESSION_BUS_ADDRESS}"

fSection "Start the session"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 _WAYFIRE_SOCKET="${run}/wayfire.socket"
if [[ -r /dev/dri/renderD128 ]]; then
	export WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128
else
	export WLR_RENDERER=pixman
fi
"${PREFIX}/bin/startlxqtukz" > "${run}/session.log" 2>&1 &
sessionPid=$!
## The session is up once lxqt-session has handed the bus its environment.
fSessionUp(){ pgrep -x lxqt-session >/dev/null && pgrep -x lxqt-panel >/dev/null; }
if fWaitFor fSessionUp; then fEcho "lxqt-session and lxqt-panel are running"; else
	tail -n 40 "${run}/session.log" >&2; fDie "the session did not come up"
fi
sleep 2

fSection "Release"
commitLine="$(grep -m1 '^LXQTUKZ_COMMIT=' "${PREFIX}/share/lxqtukz/manifest" || true)"
fEcho "${commitLine:-no LXQTUKZ_COMMIT line}"
if [[ "${commitLine}" =~ ^LXQTUKZ_COMMIT=[0-9a-f]{40}(-dirty)?$ ]]; then fCheck "the manifest names the commit" ok; else fCheck "the manifest names the commit" fail; fi
## Wayfire logs a plugin it can't load and goes on without it.
unloaded="$(grep -o 'Failed to load plugin "[^"]*"' "${run}/session.log" | sort -u | tr '\n' ' ' || true)"
if [[ -z "${unloaded}" ]]; then fCheck "Wayfire loads every plugin in its list" ok; else fCheck "Wayfire loads every plugin in its list" fail "${unloaded% }"; fi

fSection "Wallpaper"
userIni="${HOME}/.config/lxqtukz/wayfire.ini"
splash="$(grep -m1 '^splash[[:space:]]*=' "${userIni}" || true)"
fEcho "${userIni##*/}: ${splash}"
swaybgPid="$(pgrep -x swaybg | head -n1 || true)"
if [[ -z "${swaybgPid}" ]]; then
	fCheck "swaybg runs" fail "$(command -v swaybg || echo 'not installed')"
else
	image="$(tr '\0' '\n' < "/proc/${swaybgPid}/cmdline" | sed -n '/^-i$/{n;p;q}')"
	fEcho "swaybg -i ${image}"
	if [[ "${image}" == "${PREFIX}/"* && -f "${image}" ]]; then fCheck "wallpaper from the prefix" ok; else fCheck "wallpaper from the prefix" fail "${image}"; fi
fi

fSection "D-Bus services"
installed="${busDir}/${PORTAL}.service"
if [[ -f "${installed}" ]] && ! grep -q '^SystemdService=' "${installed}"; then fCheck "portal service in the runtime dir, without SystemdService" ok; else
	fCheck "portal service in the runtime dir, without SystemdService" fail "$(ls "${busDir}")"
fi
if [[ ! -e "${busDir}/org.lxqtukz.Stale.service" && -e "${busDir}/org.example.Other.service" ]]; then fCheck "earlier login's file cleared, other files kept" ok; else
	fCheck "earlier login's file cleared, other files kept" fail "$(ls "${busDir}")"
fi
fCall(){ gdbus call --session -d org.freedesktop.DBus -o /org/freedesktop/DBus -m "org.freedesktop.DBus.$1" "${@:2}"; }
fCall StartServiceByName "${PORTAL}" 0 > "${run}/start.out" 2>&1 || true
ownerPid="$(fCall GetConnectionUnixProcessID "${PORTAL}" 2>/dev/null | tr -dc '0-9' | sed 's/^32//' || true)"
## gdbus prints "(uint32 N,)", and the tr above keeps the 32 of uint32.
exe=""
[[ -z "${ownerPid}" ]] || exe="$(readlink "/proc/${ownerPid}/exe" || true)"
fEcho "${PORTAL}: $(cat "${run}/start.out") -> ${exe:-no owner}"
if [[ "${exe}" == "${PREFIX}/"* ]]; then fCheck "D-Bus starts the portal from the prefix" ok; else fCheck "D-Bus starts the portal from the prefix" fail "${exe:-not started}"; fi

fSection "xdg-desktop-portal"
if [[ ! -x /usr/libexec/xdg-desktop-portal ]]; then
	fCheck "xdg-desktop-portal finds our portal" fail "not installed in the test image"
else
	fCall StartServiceByName org.freedesktop.portal.Desktop 0 >/dev/null 2>&1 || true
	## Only portals with a backend get exported, FileChooser from ours. That
	## happens a moment after the portal takes its name.
	fFileChooser(){
		gdbus introspect --session -d org.freedesktop.portal.Desktop -o /org/freedesktop/portal/desktop 2>/dev/null \
			> "${run}/portal.introspect" || true
		grep -q 'interface org\.freedesktop\.portal\.FileChooser ' "${run}/portal.introspect"
	}
	if fWaitFor fFileChooser; then fCheck "xdg-desktop-portal finds our portal" ok; else
		fCheck "xdg-desktop-portal finds our portal" fail "no FileChooser"
	fi
fi

fSection "Keys"
## A key's value in the user's wayfire.ini, continuation lines joined.
fIni(){ ## section key
	S="[$1]" K="$2" awk '
		/^\[/ { on = ($0 == ENVIRON["S"]); next }
		on && !more && $0 ~ ("^" ENVIRON["K"] "[[:space:]]*=") { sub(/^[^=]*=[[:space:]]*/, ""); more = 1 }
		more { line = $0; cont = sub(/[[:space:]]*\\$/, "", line); out = out " " line; if (!cont) exit }
		END { gsub(/[[:space:]]+/, " ", out); sub(/^ /, "", out); print out }' "${userIni}"
}
## stipc presses the keys. The release doesn't load it, and Wayfire picks up a
## change to its file as it runs.
sed -i 's/^plugins[[:space:]]*=[[:space:]]*\\$/&\n  stipc \\/' "${userIni}"
export WAYFIRE_SOCKET="${_WAYFIRE_SOCKET}"
export WAYLAND_DISPLAY="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -n1 || true)"
fKeys(){ python3 -I "${KEYS}" "$@" >/dev/null 2>&1; }
fWaitFor fKeys shift || fDie "stipc did not load; check the plugins line in ${userIni}"
## When 2 plugins share a key, only one of them gets it. Super+E was
## both expo and the file manager, and the overview won.
dupKeys="$(awk '
	/^\[/ { sec = $0; next }
	/^[[:space:]]*#/ || !/=/ { next }
	{
		name = $0; sub(/[[:space:]]*=.*/, "", name)
		val = $0; sub(/^[^=]*=[[:space:]]*/, "", val)
		n = split(val, alts, /[[:space:]]*\|[[:space:]]*/)
		for (i = 1; i <= n; i++) {
			if (alts[i] !~ /(KEY|BTN)_[A-Z0-9]+[[:space:]]*$/) continue
			m = split(alts[i], w, /[[:space:]]+/); mods = ""; key = ""
			for (j = 1; j <= m; j++) if (w[j] ~ /^</) mods = mods " " w[j]; else if (w[j] != "") key = w[j]
			## Same modifiers in another order is the same key.
			k = split(substr(mods, 2), ms, " ")
			for (a = 2; a <= k; a++) for (b = a; b > 1 && ms[b - 1] > ms[b]; b--) { t = ms[b]; ms[b] = ms[b - 1]; ms[b - 1] = t }
			combo = ""
			for (j = 1; j <= k; j++) combo = combo ms[j] " "
			combo = combo key
			where[combo] = where[combo] " " sec name; count[combo]++
		}
	}
	END { for (c in count) if (count[c] > 1) print c ":" where[c] }' "${userIni}")"
if [[ -z "${dupKeys}" ]]; then fCheck "no key is bound twice in wayfire.ini" ok; else fCheck "no key is bound twice in wayfire.ini" fail "${dupKeys//$'\n'/; }"; fi

fSection "File manager and desktop"
## LXQtukz has neither for now. pcmanfm-qt was both, until it was dropped.
named=()
[[ ! -e "${PREFIX}/bin/pcmanfm-qt" ]] || named+=("bin/pcmanfm-qt")
for entry in "${PREFIX}"/etc/xdg/autostart/*.desktop "${PREFIX}"/share/applications/*.desktop; do
	[[ -e "${entry}" ]] || continue
	if grep -qE '^(Try)?Exec=.*pcmanfm' "${entry}"; then named+=("${entry#"${PREFIX}/"}"); fi
done
if grep -v '^[[:space:]]*#' "${userIni}" | grep -q pcmanfm; then named+=("${userIni##*/}"); fi
if ((! ${#named[@]})); then fCheck "nothing the session starts names pcmanfm-qt" ok; else fCheck "nothing the session starts names pcmanfm-qt" fail "${named[*]}"; fi
if ! pgrep -xu "${UID}" pcmanfm-qt >/dev/null; then fCheck "no pcmanfm-qt running" ok; else fCheck "no pcmanfm-qt running" fail "$(pgrep -a -xu "${UID}" pcmanfm-qt | head -n1)"; fi
## Super+E opens the home folder in the default file manager, here a stand-in
## that writes down what it was asked to open.
fEcho "$(fIni command binding_filemanager) -> $(fIni command command_filemanager)"
opened="${run}/filemanager.opened"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$@\" > '${opened}'" > "${run}/filemanager.sh"
chmod +x "${run}/filemanager.sh"
mkdir -p "${HOME}/.local/share/applications" "${HOME}/.config"
printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=Stand-in file manager" "Exec=${run}/filemanager.sh %f" "MimeType=inode/directory;" \
	> "${HOME}/.local/share/applications/lxqtukz-test-files.desktop"
printf '%s\n' "[Default Applications]" "inode/directory=lxqtukz-test-files.desktop" > "${HOME}/.config/mimeapps.list"
fKeys super+e
if fWaitFor test -s "${opened}" && [[ "$(cat "${opened}")" == "${HOME}" ]]; then fCheck "Super+E opens home in the default file manager" ok; else
	fCheck "Super+E opens home in the default file manager" fail "$(cat "${opened}" 2>/dev/null || echo 'not started')"
fi

fSection "Lock screen"
fEcho "plugins: $(fIni core plugins)"
fEcho "$(fIni command binding_lock) -> $(fIni command command_lock)"
fEcho "idle: $(fIni autostart idle)"
fEcho "session.conf: $(grep -h '^lock_command_wayland' "${PREFIX}/etc/xdg/lxqtukz/session.conf" || echo 'no lock_command_wayland')"
## gtklock needs ext-session-lock-v1, which is Wayfire's session-lock plugin.
if [[ " $(fIni core plugins) " == *" session-lock "* ]] && ! grep -q 'Failed to load plugin "session-lock"' "${run}/session.log"; then
	fCheck "session-lock plugin loaded" ok
else
	fCheck "session-lock plugin loaded" fail
fi
idlePid="$(pgrep -xu "${UID}" swayidle | head -n1 || true)"
idleArgs=""
[[ -z "${idlePid}" ]] || idleArgs="$(tr '\0' ' ' < "/proc/${idlePid}/cmdline")"
fEcho "swayidle: ${idleArgs:-not running}"
if [[ "${idleArgs}" == *" timeout "*" lxqt-leave --lockscreen"* ]]; then fCheck "swayidle locks the session when idle" ok; else
	fCheck "swayidle locks the session when idle" fail "${idleArgs:-not running}"
fi

grim "${run}/unlocked.png"
fGtklock(){ pgrep -xu "${UID}" gtklock >/dev/null; }
fLeaveGone(){ ! pgrep -xu "${UID}" lxqt-leave >/dev/null; }
started="$(date +%s%N)"
fKeys super+shift+Escape
if fWaitFor fGtklock; then fCheck "the lock key starts gtklock" ok; else fCheck "the lock key starts gtklock" fail "$(pgrep -a -u "${UID}" lxqt-leave || true)"; fi
## lxqt-leave waits for the lock command. Still there means nothing locked,
## or it showed an error box: gtklock -d exits 1 if the lock takes over a second.
if fWaitFor fLeaveGone; then
	fCheck "lxqt-leave returns once locked" ok
	fEcho "locked in $(( ($(date +%s%N) - started) / 1000000 )) ms"
else
	fCheck "lxqt-leave returns once locked" fail "still running"
fi
lockPid="$(pgrep -xu "${UID}" gtklock | head -n1 || true)"
if [[ -n "${lockPid}" ]]; then
	fEcho "gtklock: $(readlink "/proc/${lockPid}/exe" || true) $(tr '\0' ' ' < "/proc/${lockPid}/cmdline" | cut -d' ' -f2-)"
	if grep -q '/gtklock/userinfo-module\.so$' "/proc/${lockPid}/maps"; then fCheck "gtklock loads the user name module" ok; else fCheck "gtklock loads the user name module" fail; fi
	sleep 1
	grim "${run}/locked.png"
	if ! cmp -s "${run}/unlocked.png" "${run}/locked.png"; then fCheck "the lock screen shows" ok; else fCheck "the lock screen shows" fail "screen unchanged"; fi
	## A wrong password clears the box and puts up "Login failed". With the
	## clock on the same minute, that message is all that changes.
	(( 10#$(date +%S) < 50 )) || sleep 11
	grim "${run}/locked.png"
	fKeys text:notmypassword Return
	sleep 4
	grim "${run}/failed.png"
	if ! cmp -s "${run}/locked.png" "${run}/failed.png" && fGtklock; then fCheck "a wrong password shows a message and stays locked" ok; else
		fCheck "a wrong password shows a message and stays locked" fail
	fi
	## The idle lock or a suspend while already locked. A second gtklock
	## can't lock, and lxqt-leave would wait on an error box.
	mapfile -d '' sessionEnv < "/proc/$(pgrep -xu "${UID}" lxqt-session | head -n1)/environ"
	if env -i "${sessionEnv[@]}" timeout 10 lxqt-leave --lockscreen > "${run}/relock.log" 2>&1 \
		&& [[ "$(pgrep -cxu "${UID}" gtklock)" == 1 ]]; then
		fCheck "locking again while locked is quiet" ok
	else
		fCheck "locking again while locked is quiet" fail "$(pgrep -cxu "${UID}" gtklock) gtklock running"
	fi
fi
cp "${run}"/*.png "${SHOTS}/" 2>/dev/null || true

fStopAll
if ((failed)); then
	## Services the bus starts log to the bus's own output.
	tail -n 40 "${run}/bus.log" >&2
	tail -n 30 "${run}/session.log" >&2
	fDie "${failed} check(s) failed"
fi
fEcho "done"


##	History:
##		- 2026-10-14: Created.
##		- 2026-10-15: Lock screen checks.
##		- 2026-10-15: Manifest commit and plugin checks.
##		- 2026-10-16: No pcmanfm-qt; Super+P opens the default file manager.
##		- 2026-11-09: The file manager key is Super+E. No key bound twice.
