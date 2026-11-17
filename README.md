<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->
<div align="center">

![Made with](https://img.shields.io/badge/Made%20with-C%2B%2B%20%2F%20Qt6-1f425f.svg)
![License: LGPL v2.1+](https://img.shields.io/badge/License-LGPL%20v2.1%2B-blue.svg)
[![Release](https://img.shields.io/github/v/release/tukzedo/lxqtukz?include_prereleases&label=release)](https://github.com/tukzedo/lxqtukz/releases)
![Lifecycle](https://img.shields.io/badge/Lifecycle-Alpha-orange)
![Support](https://img.shields.io/badge/Support-Maintained-brightgreen)

</div>

<!-- TOC ignore:true -->
# LXQtukz

LXQt on Wayfire. A light Qt desktop on a Wayland compositor, kept current with upstream, with our own patches on top.

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Why](#why)
- [What it is](#what-it-is)
- [Status](#status)
- [Installation](#installation)
	- [Debian 13](#debian-13)
	- [NixOS](#nixos)
- [Updates and versions](#updates-and-versions)
- [Where settings live](#where-settings-live)
- [Set up development environment](#set-up-development-environment)
- [Copyright and license](#copyright-and-license)

<!-- /TOC -->

## Why

LXQt is one of the lightest full desktops there is, and Wayfire is a fast wlroots compositor. LXQt already runs on Wayfire, as one of several compositor choices. LXQtukz makes it the only choice, and builds around it:

- One compositor, set up properly.

- Every setting in one place. All the user's in `~/.config/lxqtukz/`, all the system's in `/etc/xdg/lxqtukz/`.

- Updates itself, and any past version stays one command away.

- Our own changes, kept as patches on top of upstream releases, so upstream fixes keep coming in.

It is the default desktop of tukzedo-linux, on both its Debian and its NixOS editions. It also installs on a plain Debian or NixOS system, without tukzedo-linux.

## What it is

- Upstream LXQt and Wayfire, each component pinned to an upstream release.

- Our own patches on top, kept as a patch queue per component and rebased onto each new upstream release. They may get large over time, and the tooling expects that.

- A session launcher, defaults, and an updater that tie it together.

- Our own settings app, `lxqtukz-settings`, meant to put every setting in one place. It starts with the screen, keyboard, mouse and touchpad.

Provenance and how upstream is tracked: [upstream.md](upstream.md).

## Status

Alpha. The repository, upstream tracking, patch tooling, installer, and updater are in place. The first full build of all components has not been run yet. There is no published release.

- Plans and progress: [project/backlog.md](project/backlog.md)

- Design and reasoning: [project/design.md](project/design.md)

## Installation

### Debian 13

Run this. It downloads the build for your machine and checks its checksum, then installs the runtime packages it needs with apt. It says what it's about to do first, and waits for a yes.

~~~bash
bash <(curl -fsSL https://raw.githubusercontent.com/tukzedo/lxqtukz/main/install.bash)  [--to VERSION]  [--channel stable|dev]
~~~

Then pick "LXQtukz" in your display manager's session menu.

It installs to `/opt/lxqtukz/`, beside any LXQt the distro has; the two don't conflict. `--uninstall` reverses it and leaves settings alone.

### NixOS

Add it to your system flake:

~~~nix
{
  inputs.lxqtukz.url = "github:tukzedo/lxqtukz";
  inputs.lxqtukz.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, lxqtukz, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix
        lxqtukz.nixosModules.default
        { services.lxqtukz.enable = true; }
      ];
    };
  };
}
~~~

`main` only ever gets releases, so following the bare URL follows releases.

## Updates and versions

Every release is a tag (`v0.1.0`) and a GitHub release, and stays available. `lxqtukz-update` moves between them on both Debian and NixOS:

~~~bash
lxqtukz-update                 # newest release on your channel
lxqtukz-update --list          # every release, marking installed and active
lxqtukz-update --to 0.3.1      # exactly this version, older or newer
lxqtukz-update --rollback      # back to the version before this one
lxqtukz-update --status
~~~

A daily timer runs it on its own. `/etc/xdg/lxqtukz/update.conf` turns that off, picks the channel, or pins a version (on NixOS: the `services.lxqtukz.autoUpdate` options).

- Debian: every version sits in its own `/opt/lxqtukz/versions/<version>/`. Switching is one atomic symlink change, and rollback is instant. A running session stays on the version it started with until the next login. The last 3 versions are kept by default.

- NixOS: the flake's `lxqtukz` input is re-locked to the release tag and the system rebuilt (on next boot by default). NixOS generations give a second way back.

Each release records exactly which upstream commits and how many patches went into it, in `share/lxqtukz/manifest`.

## Where settings live

| Scope   | Where                       | Notes
| :---    | :---                        | :---
| User    | `~/.config/lxqtukz/`        | Every LXQt module's settings, and `wayfire.ini`
| System  | `/etc/xdg/lxqtukz/`         | Overrides release defaults that have the same file name. On NixOS, set by `services.lxqtukz.settings`
| Release | `<prefix>/etc/xdg/lxqtukz/` | Defaults that come with the release. They change with each version, so don't edit them

A stock LXQt on the same machine keeps using `~/.config/lxqt/`, untouched.

## Set up development environment

You need git, bash, and Docker (or Podman with a Docker alias) for release builds. Everything else is fetched.

~~~bash
git clone https://github.com/tukzedo/lxqtukz.git
cd lxqtukz
cicd/upstream.bash status        # pins, patch counts, newer upstream releases
cicd/upstream.bash apply liblxqt # upstream source plus our patches, in work/src/liblxqt
cicd/build.bash                  # full Debian 13 build in a container
cicd/build.bash wayfire          # rebuild one component into the last full build
cicd/build.bash dogfood          # full build, then install it in /opt/lxqtukz on this box (sudo)
cicd/session.bash                # start the built session on a headless Wayfire, and check it
cicd/settings.bash               # settings app: lints, tests, a run on a headless Wayfire, then a copy in ~/.local/bin
cicd/tooling.bash                # checks for the cicd scripts themselves, with stubs
~~~

Changing upstream code, moving to a new upstream release, and the release process are in [project/design.md](project/design.md). Conventions for contributors are in [contributing.md](contributing.md).

## Copyright and license

LXQt is the work of the [LXQt project](https://lxqt-project.org/) and its many contributors. Wayfire is the work of the [WayfireWM project](https://wayfire.org/) and its contributors. LXQtukz is not affiliated with or endorsed by either. Report issues here, never upstream.

- Our patches to a component are under that component's license (LGPL-2.1-or-later for most of LXQt; see each upstream repository).

- LXQtukz's own desktop code is under LGPL-2.1-or-later, LXQt's own license, so code can move between us and upstream without relicensing. See `license.txt`.

- Build, install, and helper scripts are MIT, as their headers say.

> Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)<br>
> Upstream code Copyrights © [LXQt authors](https://github.com/lxqt) and [Wayfire authors](https://github.com/WayfireWM).<br />
> Licensed under [GNU LGPL v2.1 or later](https://spdx.org/licenses/LGPL-2.1-or-later.html) license. No warranty.
