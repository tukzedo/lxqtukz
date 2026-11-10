#!/usr/bin/env bash

#  shellcheck disable=2155  ## 'Declare and assign separately to avoid masking return values.' Cumbersome and unnecessary.
#  shellcheck disable=2016  ## The stubs are written with their own variables unexpanded, on purpose.

##	- Purpose: Checks the pipeline scripts themselves, on the host, against
##	  stand-ins: no docker, no network, no sudo. Each stage runs a copy of the
##	  script under test in a scratch repo.
##	- Stages, run in the order given. With none named, all run:
##	    upstream  upstream.bash status against local mirrors: tags with and
##	              without a prefix, --fetch, --summary, no-mirror fallback
##	    dogfood   build.bash dogfood with docker, sudo, the installer and the
##	              updater replaced by stubs that log what they were asked:
##	              same version, other version, none installed, in use,
##	              and settings.bash dogfood after each
##	- Syntax: cicd/tooling.bash [upstream] [dogfood]
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=utility/include/echo.bash
source "${REPO_ROOT}/cicd/utility/include/echo.bash"

fAbort(){ printf "\nTOOLING TEST ABORTED (exit %s) at line %s: %s\n\n" "$1" "$2" "$3" >&2; exit "$1"; }
trap 'fAbort $? $LINENO "$BASH_COMMAND"' ERR

stages=()
while (($#)); do case "$1" in
	upstream|dogfood) stages+=("$1"); shift ;;
	-h|--help) sed -n '/^##\t- Purpose/,/^##\tHistory/p' "${BASH_SOURCE[0]}" | sed 's/^##\t\{0,1\}//'; exit 0 ;;
	*) fDie "unknown argument: $1" ;;
esac; done
((${#stages[@]})) || stages=(upstream dogfood)

run="$(mktemp -d "${TMPDIR:-/tmp}/test_lxqtukz-tooling_$(date +%Y%m%d-%H%M%S%2N)_XXXX")"
fCleanup(){ [[ -d "${run}" && "${run}" == */test_lxqtukz-tooling_* ]] && rm -rf "${run}"; return 0; }
trap fCleanup EXIT

declare -i failed=0
fCheck(){ ## label ok|fail [detail]
	if [[ "$2" == ok ]]; then fEcho "ok: $1"; else fEcho "FAIL: $1${3:+ (${3})}"; failed=$((failed + 1)); fi
}
fSame(){ ## label got want
	if [[ "$2" == "$3" ]]; then fCheck "$1" ok; else fCheck "$1" fail "${2//$'\n'/ | }"; fi
}
## Passes when the text has the line, or with '!' first, when it doesn't.
fHas(){ ## label text [!] line
	local label="$1" text="$2" want=1
	shift 2
	if [[ "$1" == "!" ]]; then want=0; shift; fi
	local -i got=0
	grep -qxF -- "$1" <<<"${text}" && got=1
	if ((got == want)); then fCheck "${label}" ok; else fCheck "${label}" fail "${text//$'\n'/ | }"; fi
}

export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@localhost GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@localhost
fGit(){ git -c init.defaultBranch=main -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }


fStage_upstream(){
	fSection "upstream.bash status"
	local repo="${run}/upstream/repo" up="${run}/upstream/up" name out
	local -A commit=()
	mkdir -p "${repo}/cicd" "${repo}/upstream" "${repo}/patches" "${up}"
	cp -r "${REPO_ROOT}/cicd/utility" "${repo}/cicd/"
	cp "${REPO_ROOT}/cicd/upstream.bash" "${repo}/cicd/"
	for name in alpha beta gamma; do
		fGit init -q "${up}/${name}"
		fGit -C "${up}/${name}" commit -q --allow-empty -m first
		commit[${name}]="$(git -C "${up}/${name}" rev-parse HEAD)"
	done
	fGit -C "${up}/alpha" tag 1.0.0
	fGit -C "${up}/beta" tag beta-2.0
	fGit -C "${up}/beta" tag beta-2.1-rc1
	fGit -C "${up}/gamma" tag split-thing
	printf '%s %s %s %s %s -\n' \
		alpha "${up}/alpha" 1.0.0    "${commit[alpha]}" cmake \
		beta  "${up}/beta"  beta-2.0 "${commit[beta]}"  meson \
		gamma "${up}/gamma" 1.0      "${commit[gamma]}" cmake > "${repo}/upstream/components.conf"
	local status="${repo}/cicd/upstream.bash"

	"${status}" fetch > /dev/null
	out="$("${status}" status 2>&1 || true)"
	fHas "a prefixed tag matches its pin, a pre-release doesn't count" "${out}" \
		"upstream: 3 components, 0 behind upstream, 1 with no release tag found (gamma), 0 work tree(s) changed, 3 not applied"
	fSame "the table has every component" "$(grep -c '^alpha \|^beta \|^gamma ' <<<"${out}" || true)" 3

	fGit -C "${up}/alpha" tag 1.1.0
	fGit -C "${up}/beta" tag beta-2.0.1
	out="$("${status}" status --summary 2>&1 || true)"
	fHas "without --fetch, the mirror's tags" "${out}" \
		"upstream: 3 components, 0 behind upstream, 1 with no release tag found (gamma), 0 work tree(s) changed, 3 not applied"
	out="$("${status}" status --summary --fetch 2>&1 || true)"
	fHas "--fetch sees the new tags, and --summary prints 1 line" "${out}" \
		"upstream: 3 components, 2 behind upstream (alpha beta), 1 with no release tag found (gamma), 0 work tree(s) changed, 3 not applied"
	fSame "--summary is 1 line" "$(wc -l <<<"${out}")" 1

	fGit -C "${up}/beta" tag beta-2.0.2
	mv "${repo}/work/mirror/beta.git" "${run}/upstream/beta.git"
	out="$("${status}" status beta 2>&1 || true)"
	fHas "with no mirror, upstream is asked" "${out}" \
		"$(printf "%-24s %-18s %-18s %-6s %s" beta beta-2.0 "beta-2.0.2 *" 0 -)"
	mv "${run}/upstream/beta.git" "${repo}/work/mirror/beta.git"

	out="$("${status}" apply --fetch 2>&1 || true)"
	fHas "--fetch is refused for other subcommands" "${out}" "[ FAILED: --fetch and --summary are for status only ]"
}


fStage_dogfood(){
	fSection "build.bash dogfood"
	local repo="${run}/dogfood/repo" stubs="${run}/dogfood/stubs" log="${run}/dogfood/log" opt="${run}/dogfood/opt"
	local target="debian13-$(uname -m)" version="9.8.7" tarball out pid
	mkdir -p "${repo}/cicd/linux" "${repo}/upstream" "${repo}/cicd/artifacts/release" "${stubs}"
	cp -r "${REPO_ROOT}/cicd/utility" "${repo}/cicd/"
	cp "${REPO_ROOT}/upstream/components.conf" "${repo}/upstream/"
	echo "${version}" > "${repo}/version"
	tarball="${repo}/cicd/artifacts/release/lxqtukz-${version}-${target}.tar.gz"
	: > "${tarball}"
	sed "s|^DOGFOOD_ROOT=.*|DOGFOOD_ROOT=\"${opt}\"|" "${REPO_ROOT}/cicd/build.bash" > "${repo}/cicd/build.bash"
	chmod 755 "${repo}/cicd/build.bash"
	grep -qxF "DOGFOOD_ROOT=\"${opt}\"" "${repo}/cicd/build.bash" || fDie "build.bash has no DOGFOOD_ROOT line to point at the scratch dir"

	local stub
	for stub in install.bash cicd/upstream.bash cicd/settings.bash; do
		printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "${stub##*/}" "${log}" > "${repo}/${stub}"
	done
	printf '#!/usr/bin/env bash\necho "lxqtukz-update $*" >> "%s"\n' "${log}" > "${stubs}/lxqtukz-update"
	printf '#!/usr/bin/env bash\necho "docker $1" >> "%s"\n[[ "$1" != run || -z "${DOCKER_RUN_FAILS:-}" ]]\n' "${log}" > "${stubs}/docker"
	## Only the in-use check is run for real; it reads /proc.
	printf '#!/usr/bin/env bash\necho "sudo ${1##*/} ${2:-}" >> "%s"\n[[ "$1" != sh ]] || exec "$@"\n' "${log}" > "${stubs}/sudo"
	chmod 755 "${repo}/install.bash" "${repo}/cicd/upstream.bash" "${repo}/cicd/settings.bash" "${stubs}"/*

	fActive(){ rm -rf "${opt}"; [[ -z "${1:-}" ]] && return 0; mkdir -p "${opt}/versions/$1/bin"; ln -sfn "versions/$1" "${opt}/current"; }
	## Prints the stub log, then the script's exit status.
	fDogfood(){ ## args...
		: > "${log}"
		local -i rc=0
		PATH="${stubs}:${PATH}" "${repo}/cicd/build.bash" "$@" > "${run}/dogfood/out" 2>&1 || rc=$?
		cat "${log}"; echo "rc=${rc}"
	}
	local install="sudo install.bash -y" check="sudo sh -c" uninstall="lxqtukz-update --uninstall -y" settings="settings.bash dogfood"
	local start=$'docker build\nupstream.bash apply\ndocker run'

	fActive ""
	out="$(fDogfood dogfood)"
	fHas "not installed: installs" "${out}" "${install}"
	fHas "not installed: no uninstall" "${out}" ! "${uninstall}"
	fSame "not installed: build first, then install" "${out}" "${start}"$'\n'"${install}"$'\n'"${settings}"$'\nrc=0'

	fActive "${version}"
	out="$(fDogfood dogfood)"
	fSame "same version: uninstall, then install" "${out}" "${start}"$'\n'"${check}"$'\n'"${uninstall}"$'\n'"${install}"$'\n'"${settings}"$'\nrc=0'

	fActive "0.0.1"
	out="$(fDogfood dogfood)"
	fSame "other version: installs over it" "${out}" "${start}"$'\n'"${install}"$'\n'"${settings}"$'\nrc=0'

	fActive "${version}"
	mv "${stubs}/lxqtukz-update" "${run}/dogfood/lxqtukz-update"
	out="$(PATH="/usr/bin:/bin" fDogfood dogfood)"
	mv "${run}/dogfood/lxqtukz-update" "${stubs}/lxqtukz-update"
	fHas "no lxqtukz-update on PATH: the repo's install.bash uninstalls" "${out}" "install.bash --uninstall -y"

	fActive "${version}"
	cp "$(command -v sleep)" "${opt}/versions/${version}/bin/sleep"
	"${opt}/versions/${version}/bin/sleep" 30 & pid=$!
	sleep 0.3
	out="$(fDogfood dogfood)"
	kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
	fSame "same version in use: install skipped, settings still copied" "${out}" "${start}"$'\n'"${check}"$'\n'"${settings}"$'\nrc=0'

	fActive ""
	out="$(fDogfood)"
	fHas "not named: no install" "${out}" ! "${install}"
	fHas "not named: no settings copy" "${out}" ! "${settings}"
	out="$(DOCKER_RUN_FAILS=1 fDogfood dogfood)"
	fHas "failed build: no install" "${out}" ! "${install}"
	fHas "failed build: no settings copy" "${out}" ! "${settings}"
	out="$(fDogfood settings dogfood)"
	fSame "refused with a component list" "${out}" "rc=1"
	out="$(fDogfood --here dogfood)"
	fSame "refused with --here" "${out}" "rc=1"
	rm -f "${tarball}"
	out="$(fDogfood dogfood)"
	fHas "no release: no install" "${out}" ! "${install}"
	fHas "no release: fails" "${out}" "rc=1"
	fHas "no release: no settings copy" "${out}" ! "${settings}"
}


for stage in "${stages[@]}"; do "fStage_${stage}"; done
if ((failed)); then fDie "${failed} check(s) failed"; fi
fEcho "done: ${stages[*]}"


##	History:
##		- 2026-10-15: Created.
##		- 2026-11-10: dogfood checks the settings.bash dogfood call.
