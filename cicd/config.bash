# shellcheck shell=bash
# shellcheck disable=2034  ## 'appears unused.' Read by cicd.bash and hooks/pre-push, which source this.

##	Purpose:
##		- LXQtukz's settings for cicd.bash and the pre-push hook.
##		  Assignments only, since the hook sources it too.
##		- Tool pins live here. The images' Dockerfiles in cicd/linux/ repeat
##		  the ones they install. Bump a pin on purpose: change it, run the full
##		  pipeline, commit.
##	History: At bottom of file.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


projectName="lxqtukz"

## "name|version|command that prints it". A box with something else gets a
## warning, so a lint result that moved can be traced to the tool.
TOOL_PINS=(
	"shellcheck|0.10.0|shellcheck --version"
	## markdownlint-cli, the `markdownlint` command, not markdownlint-cli2.
	"markdownlint|0.49.1|markdownlint --version"
)

## Paths that don't change the product. A push to main that changes only
## these skips the merge gate. Bash patterns, matched against the whole path.
## Not license.txt, which the release has.
DOCS_PATHS=(
	'*.md'
	'project/*'
	'.github/*'
)

## Rules markdownlint skips. Every doc is one line per paragraph, so MD013 is
## always off. The backlog's next-cut marker is bold on purpose.
MARKDOWNLINT_DISABLE=(MD013)
MARKDOWNLINT_DISABLE_FOR=(
	"project/backlog.md|MD036"
)

## Rotated lint logs, gitignored. utility/lint-report.bash reads them.
LINT_LOG_DIR="cicd/artifacts/lint"

## The leak checks, "name|step function|length". The length is by measured
## time: fast ones run in every run, slow ones in all but --quick and
## --backlog-run-quick, and hours ones only in --long. --leakcheck adds every
## one to any run, and --no-leakcheck takes every one out. The name, in lower
## case, is its --backlog-run-quick area. None yet.
LEAK_CHECKS=()
## Steps that get a quarter of the CPUs, busy or not.
HEAVY_STEPS=()


##	History:
##		- 2026-11-10: Created, from tukzmon's.
