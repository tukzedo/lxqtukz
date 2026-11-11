#!/usr/bin/env bash

#  shellcheck disable=2034  ## 'appears unused.' The arrays are read by the scripts that source this.

##	- Purpose: Reads upstream/components.conf into arrays, so every script
##	  agrees on what a component is.
##	- After fComponents_Load:
##	    componentNames[]                 build order
##	    componentUrl[name] componentRef[name] componentCommit[name]
##	    componentBuild[name] componentNix[name]
##	- fComponents_Select name...    -> selectedComponents[] (all when no names given)
##	- fComponents_Patches name      -> prints the queue's patch paths, in series order
##	- Syntax: source this file after setting REPO_ROOT; it defines functions only.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


COMPONENTS_CONF="${REPO_ROOT}/upstream/components.conf"
PATCHES_DIR="${REPO_ROOT}/patches"

declare -a componentNames=()
declare -A componentUrl=() componentRef=() componentCommit=() componentBuild=() componentNix=()

fComponents_Load(){
	local name url ref commit build nix extra
	componentNames=()
	while read -r name url ref commit build nix extra; do
		[[ -z "${name}" || "${name}" == \#* ]] && continue
		[[ -n "${nix}" && -z "${extra}" ]] || fDie "components.conf: malformed row for '${name}' (want 6 columns)"
		[[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || fDie "components.conf: '${name}' commit is not a full sha"
		[[ "${build}" == "cmake" || "${build}" == "meson" ]] || fDie "components.conf: '${name}' build must be cmake or meson"
		componentNames+=("${name}")
		componentUrl[${name}]="${url}"; componentRef[${name}]="${ref}"; componentCommit[${name}]="${commit}"
		componentBuild[${name}]="${build}"; componentNix[${name}]="${nix}"
	done < "${COMPONENTS_CONF}"
	((${#componentNames[@]})) || fDie "components.conf lists no components"
}

fComponents_Select(){
	selectedComponents=()
	if (($# == 0)); then selectedComponents=("${componentNames[@]}"); return 0; fi
	local name
	for name in "$@"; do
		[[ -n "${componentUrl[${name}]:-}" ]] || fDie "unknown component: ${name}"
		selectedComponents+=("${name}")
	done
}

## Series order is the apply order. A patch file not listed in series is an
## error rather than silently skipped, since that is how a queue loses a change.
fComponents_Patches(){
	local name="$1" dir="${PATCHES_DIR}/$1" line file
	[[ -f "${dir}/series" ]] || return 0
	while read -r line; do
		[[ -z "${line}" || "${line}" == \#* ]] && continue
		[[ -f "${dir}/${line}" ]] || fDie "${name}: series lists missing patch ${line}"
		echo "${dir}/${line}"
	done < "${dir}/series"
	for file in "${dir}"/*.patch; do
		[[ -e "${file}" ]] || continue
		grep -qxF "$(basename "${file}")" "${dir}/series" || fDie "${name}: $(basename "${file}") is not listed in series"
	done
}


##	History:
##		- 2026-10-12: Created.
