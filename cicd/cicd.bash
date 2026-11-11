#!/usr/bin/env bash

#  shellcheck disable=1091  ## 'source is valid here, but shellcheck doesn't know the path to it.'
#  shellcheck disable=2034  ## 'variable appears unused.' Complains about valid use of variable indirection.
#  shellcheck disable=2153  ## 'Possible misspelling.' False hit on vars assigned in the sourced config.bash.
#  shellcheck disable=2154  ## 'referenced but not assigned.' False hit on trap strings that assign the var they use (rc=$?).
#  shellcheck disable=2317  ## 'Can't reach.' False hits on functions that only run from a trap or by name.
#  shellcheck disable=2329  ## 'This function is never invoked.' The same, for the steps, which run by name from a list.
#  shellcheck enable=require-variable-braces  ## Every expansion braced: "${var}", not "$var".

##	- Purpose: LXQtukz's local CI/CD pipeline. It runs the other scripts in
##	  cicd/ as its steps. Settings are in config.bash.
##	- Steps, fail-fast:
##	   1. Remote sync     fast-forward from upstream before anything is built
##	   2. Format          settings.bash fmt: rustfmt on the settings app, in
##	                      place. Not in the hands-off runs, where the Settings
##	                      check checks it instead
##	   3. Lint            shellcheck, markdownlint and a Python syntax check,
##	                      with the output also rotated into cicd/artifacts/lint/
##	   4. Tooling         tooling.bash: the pipeline scripts against stand-ins,
##	                      this one's options included
##	   5. Settings check  settings.bash check: rustfmt, clippy and the unit
##	                      tests of the settings app
##	   6. Upstream        upstream.bash status --summary: what's behind upstream.
##	                      It reports, and checks nothing
##	   7. Build           build.bash: every component from clean, into the
##	                      release in cicd/artifacts/release/
##	   8. Settings app    settings.bash build keys gui: the release build of the
##	                      settings app driven by keyboard on a headless Wayfire,
##	                      and a screenshot of each tab. --quick takes no
##	                      screenshots
##	   9. Installer       installer.bash: install.bash in a throwaway container
##	  10. Session         session.bash: the release's session on a headless
##	                      Wayfire
##	  11. Paste           paste.bash: copy and paste between apps
##	  12. Dogfood         build.bash --no-build dogfood: installs this run's
##	                      release on this box, with sudo, then copies the
##	                      settings app to ~/.local/bin
##	  Installer, Session and Paste test the release in cicd/artifacts/release/.
##	  A run without the Build step says which commit that one came from.
##	  A step that's off isn't counted, and the first section says why it's off.
##	  A run whose options leave no check on fails, with exit 2.
##	  Cleanup comes last, on failure and Ctrl+C too.
##	- Syntax:
##	  cicd/cicd.bash [options]
##	  Options:
##	   (none)              the default run: every step
##	   --quick             the default run without the settings app's
##	                       screenshots
##	   --long              everything. The same as the default run, until a
##	                       step takes hours. Also --slow
##	   --leakcheck         add every leak check to any run. There are none yet
##	   --no-leakcheck      take every leak check out
##	   --backlog-run-quick [AREA...]
##	                       what to run before committing backlog work: lint,
##	                       tooling and the settings check, or only the areas
##	                       named:
##	                         lint      shellcheck, markdownlint, Python syntax
##	                         tooling   tooling.bash
##	                         settings  settings.bash check
##	                         upstream  upstream.bash status --summary, only
##	                                   when named
##	                         build     the full build, only when named
##	                         app       the settings app on Wayfire, only when
##	                                   named
##	                         installer the installer checks, only when named
##	                         session   the session checks, only when named
##	                         paste     the paste checks, only when named
##	   --gate [AREA...]    another name for --backlog-run-quick
##	   --backlog-run-full  what to run once after a batch of backlog work:
##	                       every check of the default run
##	   --merge-gate        the same checks, before a merge to main. The
##	                       pre-push hook runs it. Also --ci
##	                       None of those 3 syncs, formats, dogfoods, installs,
##	                       commits, pushes, prompts, or rewrites a tracked file.
##	   --no-container      run every step on this box, which then has to be
##	                       Debian 13 with the build's packages. The installer
##	                       checks need a container, so they're skipped
##	   --no-remote         skip other hosts. There are none yet
##	   --no-sync           skip the remote sync
##	   --keep-temp         keep the run's temp folder, and print where it is
##	   --list              print the steps the other options would run, and
##	                       run nothing
##	   -q, --quiet         no prompt. Dogfood is skipped when sudo would ask
##	                       for a password
##	   -m, --message MSG   kept for the shared flags. There's no publish step,
##	                       so nothing uses it yet. Also --msg MSG and -m=MSG
##	   -h, --help          show this help
##	- Jobs: half the logical CPUs, or a quarter when the 1-minute load is over
##	  half the CPU count, worked out before each step and passed to build.bash.
##	  CICD_MAX_JOBS, when set, caps it. The whole run is under nice 19 and
##	  ionice idle.
##	- Temp: each run works in <HOST_TEMP>/lxqtukz/<YYYYmmDD-HHMMSS>_<NNN>, with
##	  TMPDIR, TEMP and TMP pointed into it. It's removed at the end, along with
##	  anything still running from it. A run folder whose run is gone goes at
##	  the next run's start, or 2 days on with --keep-temp.
##	- Lint: utility/lint-report.bash reports on the newest lint log, and its
##	  --check prints only what's new since the last look.
##	- The pre-push hook, hooks/pre-push, runs --merge-gate on a push to main.
##	  Turn it on per clone with:
##	    git config core.hooksPath cicd/hooks

##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

## One compound command, which bash reads to its end before any of it runs, so
## an edit to this file during a run can't be read at the old offset.
{

## GIT_DIR and friends, from a hook run in a linked worktree, would point every
## git call here at the wrong repo.
for gitVar in $(git rev-parse --local-env-vars 2> /dev/null || true); do unset "${gitVar}"; done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"

source "${here}/config.bash"
source "${here}/utility/include/gfs-rotate.bash"
cd "${root}"
started="${SECONDS}"


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Output

declare -i __wasLastEchoBlank=0
fEcho_ResetBlankCounter() { __wasLastEchoBlank=0; }
fEcho_Clean() {
	if [[ -n "${1:-}" ]]; then printf '%s\n' "$*"; __wasLastEchoBlank=0
	elif ((! __wasLastEchoBlank)); then echo; __wasLastEchoBlank=1; fi
}
fEcho() { if [[ -n "$*" ]]; then fEcho_Clean "[ $* ]"; else fEcho_Clean ""; fi; }
fEcho_Force() { fEcho_ResetBlankCounter; fEcho "$*"; }
__letterbox="•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••"
fSection() { fEcho_Clean; fEcho_Clean "${__letterbox}"; fEcho "$*"; }
fDie() { { fEcho_Force "FAILED: $*"; echo; } >&2; exit 1; }
fUsage() { fEcho_Clean "$* (try --help)" >&2; exit 2; }
## Local time to the hundredth. The locale can make the point a comma.
fNow() { local t="${EPOCHREALTIME/,/.}" u=''; u="${t#*.}"; printf '%(%Y%m%d-%H%M%S)T.%s' "${t%.*}" "${u:0:2}"; }
fMinSec() { printf '%dm %02ds' $(($1 / 60)) $(($1 % 60)); }

## Git that talks to the remote goes through gitsby where it's installed, so it
## uses the account the repo belongs to.
fGitRemote() { if command -v gitsby > /dev/null 2>&1; then gitsby raw git "$@"; else git "$@"; fi; }


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Options

mode="default"; areas=(); aliasNote=""; quiet=0; keepTemp=0; listOnly=0; syncOn=1; leakOpt=""; noRemote=0; noContainer=0; cliMessage=""
fMode() { [[ "${mode}" == default || "${mode}" == "$1" ]] || fUsage "${mode/#/--} and --$1 are separate runs; give one"; mode="$1"; }
while (($#)); do case "$1" in
	--quick)              fMode quick; shift ;;
	--long|--slow)        fMode long; shift ;;
	--backlog-run-quick|--gate)
		[[ "$1" == --gate ]] && aliasNote="--gate is another name for --backlog-run-quick"
		fMode backlog-run-quick; shift
		while (($#)) && [[ "$1" != -* ]]; do areas+=("$1"); shift; done ;;
	--backlog-run-full)   fMode backlog-run-full; shift ;;
	--merge-gate|--ci)
		[[ "$1" == --ci ]] && aliasNote="--ci is another name for --merge-gate"
		fMode merge-gate; shift ;;
	--leakcheck|--no-leakcheck)
		[[ -z "${leakOpt}" || "${leakOpt}" == "$1" ]] || fUsage "--leakcheck and --no-leakcheck are opposites; give one"
		leakOpt="$1"; shift ;;
	--no-container)       noContainer=1; shift ;;
	--no-remote)          noRemote=1; shift ;;
	--no-sync)            syncOn=0; shift ;;
	--keep-temp)          keepTemp=1; shift ;;
	--list)               listOnly=1; shift ;;
	-q|--quiet)           quiet=1; shift ;;
	--message=*|--msg=*|-m=*) cliMessage="${1#*=}"; shift ;;
	-m|--message|--msg)   (($# >= 2)) || fUsage "$1 needs a message"; cliMessage="$2"; shift 2 ;;
	-h|--help)            sed -n '/^##	- Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^##	\{0,1\}//'; exit 0 ;;
	*) fUsage "unknown option: $1" ;;
esac; done

handsOff=0
case "${mode}" in backlog-run-quick|backlog-run-full|merge-gate) handsOff=1 ;; esac
allAreas=(lint tooling settings upstream build app installer session paste)
for entry in "${LEAK_CHECKS[@]+"${LEAK_CHECKS[@]}"}"; do entry="${entry%%|*}"; allAreas+=("${entry,,}"); done
namedAreas="${#areas[@]}"
if [[ "${mode}" == backlog-run-quick ]]; then
	for a in "${areas[@]+"${areas[@]}"}"; do [[ " ${allAreas[*]} " == *" ${a} "* ]] || fUsage "no area '${a}'. Areas: ${allAreas[*]}"; done
	((${#areas[@]})) || areas=(lint tooling settings)
fi
((handsOff)) && [[ -n "${cliMessage}" ]] && fUsage "--${mode} never publishes, so it takes no --message"

## What turns each step on, and why one is off. Read by fPlan.
fAreaOn() { [[ "${mode}" != backlog-run-quick || " ${areas[*]} " == *" $1 "* ]]; }
declare -a planNames=() planFns=() offLines=()
fPlan() {   ## fPlan NAME FUNCTION AREA
	local name="$1" fn="$2" area="$3"
	if [[ -n "${area}" ]] && ! fAreaOn "${area}"; then offLines+=("${name}: not among the areas named"); return 0; fi
	planNames+=("${name}"); planFns+=("${fn}")
}
if ((handsOff)); then offLines+=("Remote sync: --${mode} never syncs")
elif ((! syncOn)); then offLines+=("Remote sync: --no-sync")
else fPlan "Remote sync" fStepSync ""; fi
if ((handsOff)); then offLines+=("Format: --${mode} never rewrites a file; the Settings check checks rustfmt")
else fPlan "Format" fStepFormat ""; fi
fPlan "Lint" fStepLint lint
fPlan "Tooling" fStepTooling tooling
fPlan "Settings check" fStepSettingsCheck settings
fPlan "Upstream" fStepUpstream upstream
fPlan "Build" fStepBuild build
fPlan "Settings app" fStepApp app
[[ "${mode}" != quick ]] || offLines+=("Settings app screenshots: --quick")
if ((noContainer)); then offLines+=("Installer: --no-container, and it runs install.bash as root, so only in a container")
else fPlan "Installer" fStepInstaller installer; fi
fPlan "Session" fStepSession session
fPlan "Paste" fStepPaste paste
## A leak check's length says which runs take it, per LEAK_CHECKS. Prints why
## when it's off.
fLeakWhyOff() {   ## fLeakWhyOff NAME LENGTH
	local area="${1,,}"
	[[ "${leakOpt}" != --no-leakcheck ]] || { echo "--no-leakcheck"; return 0; }
	[[ "${leakOpt}" != --leakcheck ]] || return 0
	if [[ "${mode}" == backlog-run-quick ]]; then
		[[ " ${areas[*]} " != *" ${area} "* ]] || return 0
		[[ "${2}" != fast ]] || ((namedAreas)) || return 0
		echo "--backlog-run-quick runs it only when the ${area} area is named, or with --leakcheck"; return 0
	fi
	case "${2}" in
		fast) ;;
		slow) [[ "${mode}" != quick ]] || echo "a slow leak check, so not in --quick without --leakcheck" ;;
		hours) [[ "${mode}" == long ]] || echo "takes hours, so only in --long or with --leakcheck" ;;
	esac
}
for entry in "${LEAK_CHECKS[@]+"${LEAK_CHECKS[@]}"}"; do
	IFS='|' read -r leakName leakFn leakLength <<< "${entry}"
	[[ " fast slow hours " == *" ${leakLength} "* ]] || fDie "LEAK_CHECKS: ${leakName} has no length fast, slow or hours"
	leakWhy="$(fLeakWhyOff "${leakName}" "${leakLength}")"
	if [[ -n "${leakWhy}" ]]; then offLines+=("${leakName}: ${leakWhy}"); else fPlan "${leakName}" "${leakFn}" ""; fi
done
((${#LEAK_CHECKS[@]})) || offLines+=("Leak checks: none yet${leakOpt:+, so ${leakOpt} changes nothing}")
if ((handsOff)); then offLines+=("Dogfood: --${mode} never dogfoods")
else fPlan "Dogfood" fStepDogfood ""; fi
## Off by name, until they're built. The login checks in a VM are by hand.
if ((noRemote)); then offLines+=("Other hosts: --no-remote")
else offLines+=("Other hosts: none yet"); fi
offLines+=("Publish: not part of this pipeline${cliMessage:+, so --message goes unused}")

fPlanned() { [[ " ${planFns[*]} " == *" $1 "* ]]; }
## Areas and options can turn every check off, such as the upstream area
## alone, which would leave a run that passes having checked nothing.
planChecks=0
for fn in "${planFns[@]+"${planFns[@]}"}"; do case "${fn}" in fStepSync|fStepFormat|fStepUpstream|fStepDogfood) ;; *) planChecks=$((planChecks + 1)) ;; esac; done
noChecksNote="every check is off, so this run would check nothing"

fShowPlan() {
	local i
	fSection "${projectName} cicd: ${mode}"
	[[ -z "${aliasNote}" ]] || fEcho_Clean "${aliasNote}"
	fEcho_Clean "Steps:"
	for i in "${!planNames[@]}"; do fEcho_Clean "	$((i + 1)). ${planNames[i]}"; done
	fEcho_Clean "Off:"
	for i in "${offLines[@]}"; do fEcho_Clean "	${i}"; done
}
if ((listOnly)); then
	fShowPlan
	## The test IDs come with 2026102416315763.
	fEcho_Clean "Test IDs: none yet"
	((planChecks)) || { fEcho_Clean; fEcho_Clean "Fails: ${noChecksNote}"; }
	fEcho_Clean; exit 0
fi
((planChecks)) || fUsage "${noChecksNote}. --list shows why"


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Steps. Each returns non-zero to fail, and runs inside an if, so set -e is
## off in it: every command that can fail says so with || return 1.

fStepSync() {
	local branch='' upstream='' out='' ahead=0 behind=0 dirty=0 ff=0
	branch="$(git symbolic-ref --quiet --short HEAD || true)"
	upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null || true)"
	if [[ -z "${branch}" ]]; then fEcho_Clean "WARNING: detached HEAD; nothing to sync"; return 0; fi
	if [[ -z "${upstream}" ]]; then fEcho_Clean "WARNING: ${branch} tracks no upstream; nothing to sync"; return 0; fi
	if ! out="$(fGitRemote fetch --quiet 2>&1)"; then
		fEcho_Clean "${out}"
		fEcho_Clean "WARNING: fetch failed (offline?); going on with the local tree"
		return 0
	fi
	read -r ahead behind < <(git rev-list --left-right --count "HEAD...${upstream}")
	if ((ahead && behind)); then
		fEcho_Clean "${branch} and ${upstream} have diverged (${ahead} local, ${behind} remote); reconcile by hand"
		return 1
	fi
	if ((! behind)); then
		if ((ahead)); then fEcho_Clean "${ahead} commit(s) ahead of ${upstream}, nothing to take"; else fEcho_Clean "level with ${upstream}"; fi
		return 0
	fi
	## A fast-forward refuses to touch a modified file, so stash around it.
	if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then dirty=1; fi
	if ((dirty)); then git stash push --quiet --include-untracked --message "cicd sync $(fNow)" || return 1; fi
	if git merge --ff-only --quiet "${upstream}"; then ff=1; fi
	## git keeps the entry when a pop conflicts.
	if ((dirty)) && ! git stash pop --quiet; then
		fEcho_Clean "the local changes conflict with ${upstream}; they're safe in the stash. Resolve, then 'git stash drop'"
		return 1
	fi
	((ff)) || { fEcho_Clean "fast-forward from ${upstream} failed"; return 1; }
	fEcho_Clean "fast-forwarded ${behind} commit(s) from ${upstream}"
}

## The tracked and untracked files, of the kinds given if any, into ARRAY.
## Untracked too, since they go out with the next commit. Not through a
## process substitution, which would hide git failing.
fTreeFiles() {   ## fTreeFiles ARRAY [PATHSPEC...]
	local -n treeFiles_out="${1:?}"; shift
	local listed='' f=''
	treeFiles_out=()
	listed="$(git ls-files --cached --others --exclude-standard -- "$@")" || { fEcho_Clean "git couldn't list the files"; return 1; }
	while IFS= read -r f; do [[ ! -f "${f}" ]] || treeFiles_out+=("${f}"); done <<< "${listed}"
}

## Each kind a step checks is there because the repo has some, so none means
## the list is wrong.
fSomeOf() {   ## fSomeOf KIND COUNT
	(($2)) || { fEcho_Clean "no ${1} files were found; if there are none on purpose, take its tools out of the step"; return 1; }
}

## The scripts the containers run take --here to run on this box instead.
here_=()

fStepFormat() {
	fEcho_Clean "cicd/settings.bash ${here_[*]} fmt"
	"${here}/settings.bash" "${here_[@]+"${here_[@]}"}" fmt || return 1
}

## One lint tool, its output into the lint log too.
lintLog="/dev/null"
fLintRun() { local rc=0; "$@" 2>&1 | tee -a "${lintLog}" || rc=$?; return "${rc}"; }

## One markdownlint per set of rules it skips, MARKDOWNLINT_DISABLE plus a
## file's own in MARKDOWNLINT_DISABLE_FOR, since it starts slow.
fLintMarkdown() {   ## fLintMarkdown FILE...
	local f entry off i rc=0
	local -a files=("$@") offOf=() sets=() group=() rules=()
	local -A known=()
	for f in "${files[@]}"; do
		off="${MARKDOWNLINT_DISABLE[*]}"
		for entry in "${MARKDOWNLINT_DISABLE_FOR[@]}"; do [[ "${entry%%|*}" != "${f}" ]] || off+=" ${entry#*|}"; done
		offOf+=("${off}")
		[[ -n "${known[=${off}]:-}" ]] || { known["=${off}"]=1; sets+=("${off}"); }
	done
	for off in "${sets[@]}"; do
		group=()
		for i in "${!files[@]}"; do [[ "${offOf[i]}" != "${off}" ]] || group+=("${files[i]}"); done
		read -r -a rules <<< "${off}"
		fLintRun markdownlint --disable "${rules[@]}" -- "${group[@]}" || rc=1
	done
	return "${rc}"
}

## A shell script is one named *.bash, a hook, or one with a bash shebang,
## such as the ones in source/bin/.
fIsShell() {
	local first=''
	case "$1" in *.bash|cicd/hooks/*) return 0 ;; patches/*|*.*) return 1 ;; esac
	{ IFS= read -r first < "$1"; } 2> /dev/null || return 1
	[[ "${first}" == '#!'*bash* ]]
}

fStepLint() {
	local f pin pinName pinWant pinCmd have
	local -a failed=() files=() shFiles=() mdFiles=() pyFiles=() pinArgv=()
	if mkdir -p -- "${root}/${LINT_LOG_DIR}" 2> /dev/null; then
		lintLog="${root}/${LINT_LOG_DIR}/lint_$(printf '%(%Y%m%d-%H%M%S)T' -1).log"
		: > "${lintLog}"
	fi
	for pin in "${TOOL_PINS[@]}"; do
		pinName="${pin%%|*}"; pinWant="${pin#*|}"; pinCmd="${pinWant#*|}"; pinWant="${pinWant%%|*}"
		read -r -a pinArgv <<< "${pinCmd}"
		have="$("${pinArgv[@]}" 2> /dev/null || true)"
		if [[ -z "${have}" ]]; then fLintRun echo "WARNING: ${pinName} isn't installed (pinned ${pinWant})"
		elif [[ "${have}" != *"${pinWant}"* ]]; then fLintRun echo "WARNING: ${pinName} drifted from pin ${pinWant}: ${have//$'\n'/ }"; fi
	done
	fTreeFiles files || failed+=("git ls-files")
	for f in "${files[@]+"${files[@]}"}"; do
		case "${f}" in
			patches/*) ;;
			*.md) mdFiles+=("${f}") ;;
			*.py) pyFiles+=("${f}") ;;
			*) if fIsShell "${f}"; then shFiles+=("${f}"); fi ;;
		esac
	done
	fSomeOf shell "${#shFiles[@]}" || failed+=("no shell files")
	fSomeOf Markdown "${#mdFiles[@]}" || failed+=("no Markdown files")
	fSomeOf Python "${#pyFiles[@]}" || failed+=("no Python files")

	## SCRIPTDIR, so each script's own source= paths are read from beside it.
	if ! command -v shellcheck > /dev/null 2>&1; then
		failed+=("shellcheck (not installed)")
	elif ((${#shFiles[@]})); then
		fEcho_Clean "shellcheck: ${#shFiles[@]} file(s)"
		if fLintRun shellcheck -x -P SCRIPTDIR "${shFiles[@]}"; then fEcho_Clean "shellcheck: clean"; else failed+=(shellcheck); fi
	fi
	## Not on every box. The pin's warning says so in the log.
	if ! command -v markdownlint > /dev/null 2>&1; then
		fEcho_Clean "WARNING: markdownlint isn't installed, so the Markdown isn't linted"
	elif ((${#mdFiles[@]})); then
		fEcho_Clean "markdownlint: ${#mdFiles[@]} file(s)"
		if fLintMarkdown "${mdFiles[@]}"; then fEcho_Clean "markdownlint: clean"; else failed+=(markdownlint); fi
	fi
	## A parse only, which writes no __pycache__ into the tree.
	if ((${#pyFiles[@]})); then
		fEcho_Clean "python3 syntax: ${#pyFiles[@]} file(s)"
		if fLintRun python3 -I -c 'import ast, sys
for p in sys.argv[1:]:
	with open(p, encoding="utf-8") as f: ast.parse(f.read(), p)' "${pyFiles[@]}"; then fEcho_Clean "python3 syntax: clean"; else failed+=("python3 syntax"); fi
	fi
	if [[ "${lintLog}" != /dev/null ]]; then
		printf '[ lint: done, %d failed ]\n' "${#failed[@]}" >> "${lintLog}"
		gfs_rotate "${root}/${LINT_LOG_DIR}" lint log > /dev/null 2>&1 || true
	fi
	lintLog="/dev/null"
	((${#failed[@]} == 0)) || { fEcho_Clean "lint failed: ${failed[*]}"; return 1; }
}

fStepTooling() {
	fEcho_Clean "cicd/tooling.bash"
	"${here}/tooling.bash" || return 1
}

fStepSettingsCheck() {
	fEcho_Clean "cicd/settings.bash ${here_[*]} check"
	"${here}/settings.bash" "${here_[@]+"${here_[@]}"}" check || return 1
}

fStepUpstream() {
	fEcho_Clean "cicd/upstream.bash status --summary"
	"${here}/upstream.bash" status --summary || return 1
}

fStepBuild() {
	fEcho_Clean "cicd/build.bash ${here_[*]} --jobs ${jobs}"
	"${here}/build.bash" "${here_[@]+"${here_[@]}"}" --jobs "${jobs}" || return 1
}

fStepApp() {
	local -a stages=(build keys gui)
	[[ "${mode}" != quick ]] || stages=(build keys)
	fEcho_Clean "cicd/settings.bash ${here_[*]} ${stages[*]}"
	"${here}/settings.bash" "${here_[@]+"${here_[@]}"}" "${stages[@]}" || return 1
}

## The release the next steps test, and the commit it came from, when this
## run didn't build it. One from an older commit is still tested, and said.
releaseSaid=0
fReleaseNote() {
	local ver='' tarball='' commit='' head=''
	((! releaseSaid)) || return 0
	releaseSaid=1
	fPlanned fStepBuild && return 0
	ver="$(< "${root}/version")"
	tarball="${root}/cicd/artifacts/release/lxqtukz-${ver}-debian13-$(uname -m).tar.gz"
	[[ -f "${tarball}" ]] || { fEcho_Clean "no release at ${tarball#"${root}/"}; the Build step makes one"; return 0; }
	commit="$(tar -xzOf "${tarball}" "${ver}/share/lxqtukz/manifest" 2> /dev/null | sed -n 's/^LXQTUKZ_COMMIT=//p' || true)"
	head="$(git rev-parse HEAD 2> /dev/null || true)"
	fEcho_Clean "release: built $(date -r "${tarball}" '+%Y-%m-%d %H:%M'), from ${commit:-an unknown commit}"
	[[ "${commit}" == "${head}" ]] || fEcho_Clean "WARNING: that isn't this checkout's HEAD, ${head:0:12}, so it may not have what changed since"
}

fStepInstaller() {
	fReleaseNote
	if ((${#here_[@]})); then fEcho_Clean "WARNING: no docker, so the installer checks went unchecked"; return 0; fi
	fEcho_Clean "cicd/installer.bash"
	"${here}/installer.bash" || return 1
}

fStepSession() {
	fReleaseNote
	fEcho_Clean "cicd/session.bash ${here_[*]}"
	"${here}/session.bash" "${here_[@]+"${here_[@]}"}" || return 1
}

fStepPaste() {
	fReleaseNote
	fEcho_Clean "cicd/paste.bash ${here_[*]}"
	"${here}/paste.bash" "${here_[@]+"${here_[@]}"}" || return 1
}

## Installs the release this run built. Without the Build step there's no
## fresh one, so only the settings app is copied. Under --quiet a sudo that
## would ask for a password skips the install rather than prompt.
fStepDogfood() {
	if ! fPlanned fStepBuild; then
		fEcho_Clean "this run didn't build a release, so only the settings app: cicd/settings.bash dogfood"
		"${here}/settings.bash" dogfood || return 1
		return 0
	fi
	if ((quiet)) && ! sudo -n true 2> /dev/null; then
		fEcho_Clean "WARNING: --quiet, and sudo would ask for a password, so the release wasn't installed"
		"${here}/settings.bash" dogfood || return 1
		return 0
	fi
	fEcho_Clean "cicd/build.bash --no-build dogfood"
	"${here}/build.bash" --no-build dogfood || return 1
}


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Machine use

## Children inherit both.
renice -n 19 -p "$$" > /dev/null 2>&1 || true
if command -v ionice > /dev/null 2>&1; then ionice -c 3 -p "$$" > /dev/null 2>&1 || true; fi

## Half the CPUs, a quarter when the box is busy, and a quarter for the heavy
## steps either way. Never under 1. Sets jobs and loadNote.
cores="$(nproc 2> /dev/null || echo 2)"
jobs=1; loadNote=""
fJobs() {
	local load='' busy=0 heavyJobs=1
	read -r load _ < /proc/loadavg || load=0
	## Load against half the CPUs, both in hundredths, with no float math.
	load="${load%%.*}${load#*.}"
	if (( 10#${load} > cores * 50 )); then busy=1; fi
	jobs=$((busy ? cores / 4 : cores / 2)); ((jobs >= 1)) || jobs=1
	heavyJobs=$((cores / 4)); ((heavyJobs >= 1)) || heavyJobs=1
	## A caller sharing the box can set a lower cap. Digits only, since it goes
	## into arithmetic.
	if [[ "${CICD_MAX_JOBS:-}" =~ ^[1-9][0-9]{0,3}$ ]]; then
		((jobs <= CICD_MAX_JOBS)) || jobs="${CICD_MAX_JOBS}"
		((heavyJobs <= CICD_MAX_JOBS)) || heavyJobs="${CICD_MAX_JOBS}"
	fi
	[[ "${1:-}" != heavy ]] || jobs="${heavyJobs}"
	printf -v loadNote '%s of %s CPUs, load %d.%02d' "${jobs}" "${cores}" $((10#${load} / 100)) $((10#${load} % 100))
	if ((busy)); then loadNote+=", busy"; fi
	if [[ "${1:-}" == heavy ]]; then loadNote+=", a heavy step"; fi
}


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Temp folder and cleanup

source "${here}/utility/include/run-tmp.bash"
staleGone="$(fSweepStale)"
fRunTmpMake || fDie "could not make a temp folder under ${HOST_TEMP}/${projectName}"
export TMPDIR="${runTmp}" TEMP="${runTmp}" TMP="${runTmp}"
## Marked at the start, so a kept run that was killed is kept too.
((! keepTemp)) || : > "${runTmp}/keep"

runSaid=0; cleaned=0
fCleanup() {
	local stopped=0 kb=''
	((cleaned)) && return 0
	cleaned=1
	trap '' INT TERM HUP
	((runSaid)) || printf '\n[ CICD ABORTED (stopped) ]\n' >&2
	stopped="$(fStopLeftovers "${runTmp}")"
	fSection "$(fNow): Cleanup"
	((stopped == 0)) || fEcho_Clean "stopped ${stopped} process(es) still running from this run's temp folder"
	((staleGone == 0)) || fEcho_Clean "removed ${staleGone} stale run folder(s)"
	if ((keepTemp)); then
		fEcho_Clean "kept the temp folder: ${runTmp}"
	else
		kb="$(du -sk -- "${runTmp}" 2> /dev/null | cut -f1 || true)"
		if fSafeRm "${runTmp}"; then fEcho_Clean "removed this run's temp folder, about $(( (${kb:-0} + 512) / 1024 )) MB"; fi
	fi
}
trap 'fCleanup; fEcho_Clean' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'rc=$?; runSaid=1; printf "\n[ CICD ABORTED (exit %s) at line %s: %s ]\n" "${rc}" "${LINENO}" "${BASH_COMMAND}" >&2; exit "${rc}"' ERR


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Run

## The scripts' own containers need docker. With none, they run here.
hostNote=""
if ((noContainer)); then
	here_=(--here); hostNote="--no-container, so the steps run on this box"
elif ! command -v docker > /dev/null 2>&1 || ! timeout 30 docker info > /dev/null 2>&1; then
	here_=(--here); hostNote="no docker that answers, so the steps run on this box"
fi

fJobs
fShowPlan
fEcho_Clean "Jobs:	${loadNote}"
fEcho_Clean "Temp:	${runTmp}"
[[ -z "${hostNote}" ]] || fEcho_Clean "Host:	${hostNote}"
fEcho_Clean

stepCount="${#planNames[@]}"; lastNote=""
for i in "${!planNames[@]}"; do
	n=$((i + 1)); name="${planNames[i]}"
	if [[ " ${HEAVY_STEPS[*]+"${HEAVY_STEPS[*]}"} " == *" ${planFns[i]} "* ]]; then fJobs heavy; else fJobs; fi
	fEcho_Clean; fEcho_Clean "${__letterbox}"
	fEcho "$(fNow): Step ${n} of ${stepCount}; Starting ${name}"
	if [[ "${loadNote}" != "${lastNote}" ]]; then fEcho_Clean "jobs: ${loadNote}"; lastNote="${loadNote}"; fi
	stepStart="${SECONDS}"
	if "${planFns[i]}"; then
		fEcho_Clean "took $(fMinSec $((SECONDS - stepStart)))"
		fEcho_ResetBlankCounter
		fEcho "$(fNow): Step ${n} of ${stepCount}; PASS ${name}"
		fEcho_Clean
	else
		fEcho_Clean "took $(fMinSec $((SECONDS - stepStart)))"
		fEcho_ResetBlankCounter
		fEcho "$(fNow): Step ${n} of ${stepCount}; FAIL ${name}"
		fEcho_Clean
		runSaid=1
		exit 1
	fi
done

runSaid=1
fCleanup
fSection "${projectName} CI/CD: done. ($(fMinSec $((SECONDS - started))))"
exit 0
}


##	History:
##		- 2026-11-10: Created from tukzmon's engine: the shared flags, step
##		  lines, CPU caps under nice and ionice, a temp folder per run behind
##		  fSafeRm, lint logs, and the pre-push hook. The steps are the other
##		  cicd/ scripts.
