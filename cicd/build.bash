#!/usr/bin/env bash

#  shellcheck disable=2155  ## 'Declare and assign separately to avoid masking return values.' Cumbersome and unnecessary.

##	- Purpose: Builds a Debian LXQtukz release: every pinned component with its
##	  patch queue, into one versioned prefix, then the release assets the
##	  installer and updater download.
##	- Runs in the debian13 container (cicd/linux/Dockerfile) unless --here is
##	  given. Nothing is installed on the host.
##	- The prefix is baked in as /opt/lxqtukz/versions/<version>, which is where
##	  the installer unpacks it. Fixed per version on purpose: LXQt and Wayfire
##	  both compile install paths in, and a fixed path is what lets any number
##	  of versions sit side by side.
##	- Release assets, in cicd/artifacts/release/. install.bash depends on these
##	  names, so change both together:
##	    lxqtukz-<version>-<target>.tar.gz      one top-level dir, '<version>/'
##	    lxqtukz-<version>-<target>-deps.txt    Debian packages it needs at run time
##	    lxqtukz-<version>-sha256sums.txt
##	- Syntax: cicd/build.bash [--here] [--jobs N] [--no-build] [component...] [dogfood]
##	    component...  build only these (into the prefix of the last full build, kept
##	                  in work/prefix/); default all, from clean.
##	                  'settings' is our settings app, source/settings/.
##	    dogfood       after a full build, installs its release on this box with
##	                  install.bash --from. The same version as the one installed
##	                  is uninstalled first, since the installer skips a version
##	                  it is already on. Needs sudo, so it only runs when named.
##	                  Then settings.bash dogfood copies the settings app to
##	                  ~/.local/bin.
##	    --no-build    with dogfood, installs the release already in
##	                  cicd/artifacts/release/, without building it first.
##	                  cicd.bash's Dogfood step does that, after its own Build.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=utility/include/echo.bash
source "${REPO_ROOT}/cicd/utility/include/echo.bash"
# shellcheck source=utility/include/components.bash
source "${REPO_ROOT}/cicd/utility/include/components.bash"

fAbort(){ printf "\nBUILD ABORTED (exit %s) at line %s: %s\n\n" "$1" "$2" "$3" >&2; exit "$1"; }
trap 'fAbort $? $LINENO "$BASH_COMMAND"' ERR

IMAGE="lxqtukz-build-debian13"
TARGET="debian13-$(uname -m)"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/version")"
PREFIX="/opt/lxqtukz/versions/${VERSION}"
BUILD_DIR="${REPO_ROOT}/work/build/${TARGET}"
ARTIFACTS="${REPO_ROOT}/cicd/artifacts/release"

declare -i here=0 noBuild=0
## Half the cores, so a build leaves the machine usable.
declare -i jobs=$(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 ))
only=()
while (($#)); do case "$1" in
	--here) here=1; shift ;;
	--jobs) jobs="${2:?}"; shift 2 ;;
	--no-build) noBuild=1; shift ;;
	-h|--help) sed -n '/^##\t- Purpose/,/^##\tHistory/p' "${BASH_SOURCE[0]}" | sed 's/^##\t\{0,1\}//'; exit 0 ;;
	-*) fDie "unknown option: $1" ;;
	*) only+=("$1"); shift ;;
esac; done

## Dogfood is a step on the host, not something to build.
declare -i dogfood=0
names=()
for name in "${only[@]+"${only[@]}"}"; do
	if [[ "${name}" == dogfood ]]; then dogfood=1; else names+=("${name}"); fi
done
only=("${names[@]+"${names[@]}"}")
if ((dogfood)); then
	((! ${#only[@]})) || fDie "dogfood needs a full build; partial builds write no release"
	((! here)) || fDie "dogfood runs on the host after the container build, so not with --here"
fi
((! noBuild || dogfood)) || fDie "--no-build is only for dogfood"

## The settings app is built from this repo, so it is picked out of the list
## before the rest is matched against components.conf.
declare -i withSettings=0
upstreamOnly=()
for name in "${only[@]+"${only[@]}"}"; do
	if [[ "${name}" == settings ]]; then withSettings=1; else upstreamOnly+=("${name}"); fi
done
((${#only[@]})) || withSettings=1


fCommit(){
	local commit
	commit="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
	[[ -z "$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null || true)" ]] || commit="${commit}-dirty"
	echo "${commit}"
}

DOGFOOD_ROOT="/opt/lxqtukz"

## Installs this build's release on this box. The installer says "already on"
## and does nothing for the version that is active, so that one is removed
## first. Any other version installs over it, and stays a rollback away.
fStage_dogfood(){
	fSection "Dogfood"
	local tarball="${ARTIFACTS}/lxqtukz-${VERSION}-${TARGET}.tar.gz" active="" uninstaller
	[[ -f "${tarball}" ]] || fDie "no release at ${tarball}"
	[[ ! -L "${DOGFOOD_ROOT}/current" ]] || active="$(basename "$(readlink "${DOGFOOD_ROOT}/current")")"
	fEcho_Clean "installed: ${active:-none}, built: ${VERSION}"
	if [[ "${active}" == "${VERSION}" ]]; then
		## Uninstall takes the dir out from under a session still running it.
		if sudo sh -c "grep -qs '${DOGFOOD_ROOT}/versions/${VERSION}/' /proc/[0-9]*/maps"; then
			fEcho "skipped: a running session uses ${VERSION}; log out of it and run the dogfood stage again"
			return 0
		fi
		uninstaller="$(command -v lxqtukz-update || true)"
		if [[ -z "${uninstaller}" ]]; then
			fEcho "lxqtukz-update isn't on PATH; uninstalling with this repo's install.bash"
			"${REPO_ROOT}/install.bash" --uninstall -y
		else
			"${uninstaller}" --uninstall -y
		fi
	fi
	sudo "${REPO_ROOT}/install.bash" -y --from "${tarball}"
	fEcho "installed: ${DOGFOOD_ROOT}/versions/${VERSION}"
}


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Outside: hand off to the container

if ((! here)); then
	if ((noBuild)); then
		fStage_dogfood
		"${REPO_ROOT}/cicd/settings.bash" dogfood
		exit 0
	fi
	command -v docker >/dev/null || fDie "docker (or podman as docker) is required; or use --here on a Debian 13 box"
	fSection "Build image ${IMAGE}"
	docker build -q -t "${IMAGE}" "${REPO_ROOT}/cicd/linux" >/dev/null
	## Sources are fetched and patched on the host, where git credentials and
	## the mirrors live; the container only compiles.
	fSection "Fetch and apply upstream"
	if ((${#only[@]} == 0 || ${#upstreamOnly[@]})); then
		"${REPO_ROOT}/cicd/upstream.bash" apply "${upstreamOnly[@]+"${upstreamOnly[@]}"}"
	fi
	fSection "Build in container"
	## The prefix lives in the tree, so a partial build has the rest of it to
	## install over and stage.
	mkdir -p "${REPO_ROOT}/work/prefix/${TARGET}"
	## Git in the container refuses the repo, which isn't root's, and in a
	## worktree its .git points outside the mount. So the commit is read here.
	inContainer=(docker run --rm -i
		-v "${REPO_ROOT}:/src" -w /src
		-v "${REPO_ROOT}/work/prefix/${TARGET}:$(dirname "${PREFIX}")"
		-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e LXQTUKZ_COMMIT="$(fCommit)"
		"${IMAGE}" /src/cicd/build.bash --here --jobs "${jobs}" "${only[@]+"${only[@]}"}")
	((dogfood)) || exec "${inContainer[@]}"
	"${inContainer[@]}"
	fStage_dogfood
	## Its own copy in ~/.local/bin, so it runs even when the install was skipped.
	"${REPO_ROOT}/cicd/settings.bash" dogfood
	exit 0
fi


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Inside: compile

## The container runs as root. Hand what it wrote in the tree back to the
## host user however the build ends, so a failed build leaves nothing behind
## that a later build as that user cannot write over.
fGiveBack(){
	[[ -n "${HOST_UID:-}" ]] || return 0
	local dir
	for dir in "${ARTIFACTS}" "${REPO_ROOT}/work/build" "${REPO_ROOT}/work/cargo" "${REPO_ROOT}/work/prefix"; do
		[[ ! -e "${dir}" ]] || chown -R "${HOST_UID}:${HOST_GID:?}" "${dir}"
	done
}
trap fGiveBack EXIT

fComponents_Load
if ((${#only[@]} && ! ${#upstreamOnly[@]})); then
	selectedComponents=()
else
	fComponents_Select "${upstreamOnly[@]+"${upstreamOnly[@]}"}"
fi

## A full build starts from an empty prefix, so nothing stale ends up in a release.
if ((${#only[@]} == 0)); then rm -rf "${PREFIX}"; fi
## A partial build over a prefix no full build has finished has nothing to stage.
declare -i stageable=1
[[ ${#only[@]} -eq 0 || -f "${PREFIX}/share/lxqtukz/manifest" ]] || stageable=0
mkdir -p "${PREFIX}" "${BUILD_DIR}"
stamp="$(mktemp)"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export CMAKE_PREFIX_PATH="${PREFIX}"
export PATH="${PREFIX}/bin:${PATH}"
## Absolute rpath: the prefix is fixed per version, so this always resolves,
## and our libs win over any LXQt the distro also has installed.
rpath="${PREFIX}/lib"

for name in "${selectedComponents[@]+"${selectedComponents[@]}"}"; do
	srcDir="${REPO_ROOT}/work/src/${name}"; bld="${BUILD_DIR}/${name}"
	[[ -d "${srcDir}" ]] || fDie "${name}: no source tree; run 'cicd/upstream.bash apply ${name}'"
	extra=()
	if [[ -f "${REPO_ROOT}/upstream/flags/${name}" ]]; then
		while read -r line; do [[ -z "${line}" || "${line}" == \#* ]] || extra+=("${line}"); done < "${REPO_ROOT}/upstream/flags/${name}"
	fi
	fSection "${name} ${componentRef[${name}]} (${componentBuild[${name}]})"
	rm -rf "${bld}"
	case "${componentBuild[${name}]}" in
		cmake)
			cmake -S "${srcDir}" -B "${bld}" -G Ninja -Wno-dev \
				-DCMAKE_BUILD_TYPE=Release \
				-DCMAKE_INSTALL_PREFIX="${PREFIX}" \
				-DCMAKE_INSTALL_LIBDIR=lib \
				-DCMAKE_INSTALL_SYSCONFDIR="${PREFIX}/etc" \
				-DCMAKE_INSTALL_RPATH="${rpath}" \
				-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
				-DLXQT_ETC_XDG_DIR="${PREFIX}/etc/xdg" \
				-DUPDATE_TRANSLATIONS=OFF \
				"${extra[@]+"${extra[@]}"}"
			cmake --build "${bld}" -j "${jobs}"
			cmake --install "${bld}"
			;;
		meson)
			LDFLAGS="-Wl,-rpath,${rpath}" meson setup "${bld}" "${srcDir}" \
				--prefix="${PREFIX}" --libdir=lib --sysconfdir="${PREFIX}/etc" --buildtype=release \
				"${extra[@]+"${extra[@]}"}"
			ninja -C "${bld}" -j "${jobs}"
			meson install -C "${bld}" --quiet
			;;
	esac
done


if ((withSettings)); then
	fSection "lxqtukz-settings"
	## Cargo's cache sits in the tree, not under /usr, so the check below
	## doesn't take it for a component installing outside the prefix.
	CARGO_HOME="${REPO_ROOT}/work/cargo" cargo build --release --locked -j "${jobs}" \
		--manifest-path "${REPO_ROOT}/source/settings/Cargo.toml" --target-dir "${BUILD_DIR}/settings"
	install -Dm755 "${BUILD_DIR}/settings/release/lxqtukz-settings" "${PREFIX}/bin/lxqtukz-settings"
fi


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# Inside: check, stage, package

## Anything a component installed outside the prefix would be missing from the
## release. Lists them instead of guessing a fix; each needs a flag or a patch.
fSection "Check for files installed outside the prefix"
strays="$(find /usr /etc -xdev -newer "${stamp}" -type f 2>/dev/null | grep -v -e '^/etc/ld.so.cache$' -e '/__pycache__/' || true)"
rm -f "${stamp}"
if [[ -n "${strays}" ]]; then
	# shellcheck disable=2001  ## Indents every line, which a parameter expansion can't.
	echo "${strays}" | sed 's/^/  /'
	fDie "components installed files outside ${PREFIX}"
fi
fEcho "none"

if ((! stageable)); then
	fEcho "no full build in ${PREFIX} yet; not staged"
	exit 0
fi

"${REPO_ROOT}/cicd/utility/stage-prefix.bash" "${PREFIX}" "/opt/lxqtukz/current" "${VERSION}" "${LXQTUKZ_COMMIT:-$(fCommit)}" "${TARGET}"

## Partial builds are for iterating; only a full build makes release assets.
((${#only[@]} == 0)) || { fEcho "partial build; no release assets written"; exit 0; }

fSection "Runtime dependencies"
## Every shared library our binaries need that the prefix does not provide,
## mapped to the Debian package that provides it. This is the list the installer
## hands to apt.
deps="$(
	find "${PREFIX}" -type f -exec file --no-pad --separator '|' {} + | awk -F'|' '/ELF/ {print $1}' \
		| xargs -r ldd 2>/dev/null | awk '/=> \// {print $3}' | grep -v "^${PREFIX}/" | sort -u \
		| xargs -r -n1 readlink -f | xargs -r dpkg -S 2>/dev/null | cut -d: -f1 | sort -u
)"
## Run-time programs the session starts by name, and the QML modules the
## settings app loads, none of which ldd can see. killall is in wayfire.ini's
## [autostart], and xdg-desktop-portal is what runs our portal. lxqtukz-lock
## runs gtklock and needs pgrep, swayidle is the idle lock in [autostart], and
## gtklock's user name module gets the name from AccountsService. gtklock's
## icons are SVG, which GTK can't draw without librsvg2-common.
qml="qt6-wayland qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts
	qml6-module-qtquick-window qml6-module-qtquick-templates qml6-module-qtqml-workerscript
	qml6-module-org-kde-desktop"
locker="gtklock gtklock-userinfo-module accountsservice librsvg2-common swayidle procps"
# shellcheck disable=2086  ## Word splitting is the point: these are lists.
deps="$(printf '%s\n' ${deps} ${qml} ${locker} dbus-x11 dbus-bin xwayland swaybg psmisc xdg-desktop-portal | sort -u)"
# shellcheck disable=2001  ## Indents every line, which a parameter expansion can't.
echo "${deps}" | sed 's/^/  /'

fSection "Package"
mkdir -p "${ARTIFACTS}"
base="lxqtukz-${VERSION}-${TARGET}"
tar -C "$(dirname "${PREFIX}")" -czf "${ARTIFACTS}/${base}.tar.gz" "${VERSION}"
echo "${deps}" > "${ARTIFACTS}/${base}-deps.txt"
## One sums file per version, covering every target built for it so far.
( cd "${ARTIFACTS}" && sha256sum "lxqtukz-${VERSION}-"*.tar.gz "lxqtukz-${VERSION}-"*-deps.txt > "lxqtukz-${VERSION}-sha256sums.txt" )
# shellcheck disable=2012  ## Shown to a person, never parsed.
ls -l "${ARTIFACTS}" | sed 's/^/  /'


##	History:
##		- 2026-10-12: Created.
##		- 2026-10-14: Builds the settings app.
##		- 2026-10-14: Prefix kept in work/prefix/, so a partial build can stage.
##		- 2026-10-15: The host reads the commit for the manifest.
##		- 2026-10-15: dogfood stage.
##		- 2026-11-10: dogfood runs settings.bash dogfood too.
##		- 2026-11-10: --no-build, for cicd.bash's Dogfood step.
