<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD055 -- Table pipe style [Expected: leading_and_trailing; Actual: leading_only; Missing trailing pipe] -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

<!-- TOC ignore:true -->
# LXQtukz design

Design and decisions for LXQt on Wayfire, built from upstream with our own patches. Goes with [backlog.md](backlog.md).

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Overview](#overview)
	- [What and why](#what-and-why)
	- [Requirements](#requirements)
	- [Targets](#targets)
	- [Open questions](#open-questions)
- [Project structure](#project-structure)
	- [Folder structure](#folder-structure)
- [Upstream tracking](#upstream-tracking)
	- [Why a patch queue](#why-a-patch-queue)
	- [Workflow](#workflow)
	- [Components](#components)
- [Configuration model](#configuration-model)
- [Session](#session)
- [Install layout and versions](#install-layout-and-versions)
	- [Debian](#debian)
	- [NixOS](#nixos)
	- [Updater](#updater)
- [Delivery](#delivery)
- [Decisions along the way](#decisions-along-the-way)

<!-- /TOC -->

## Overview

### What and why

LXQtukz is LXQt on the Wayfire compositor, built from upstream releases plus our own patches. It's the default desktop for tukzedo-linux on both the Debian and NixOS editions. It also installs on plain Debian and NixOS.

It follows upstream releases for as long as the project lives. The patches may get large, so the tooling treats a big, long-lived patch queue as normal.

### Requirements

| Requirement                                                    | Met by
| :---                                                           | :---
| Default desktop for tukzedo-linux, Debian or NixOS underneath  | One source tree with 2 install paths, a Debian prefix build and a NixOS flake. See [Install layout and versions](#install-layout-and-versions).
| Installs without tukzedo-linux, starting with Debian and NixOS | `install.bash` one-liner on Debian 13, flake and module on NixOS. Nothing assumes tukzedo-linux.
| Auto-update from GitHub                                        | `lxqtukz-update --auto` on a daily systemd timer, reading GitHub releases. See [Updater](#updater).
| Any older version can be picked on update                      | Every release is a tag and a GitHub release that never changes. `--to VERSION` and `PIN=` go to any of them, older or newer.
| System and user settings each in one place                     | `/etc/xdg/lxqtukz/` and `~/.config/lxqtukz/`. See [Configuration model](#configuration-model).
| Track upstream, with our own patches that may get large        | Pins plus a patch queue per component, rebased on each bump. See [Upstream tracking](#upstream-tracking).
| Wayfire as the compositor                                      | The only compositor. `startlxqtukz` starts it directly.

### Targets

- Debian 13 (trixie), x86_64 first and arm64 next. Qt 6.8 and glibc 2.41 at minimum.

- NixOS on nixos-unstable, x86_64 and aarch64.

- Later: Debian 14 once it's out, and Ubuntu LTS. Each Debian-family target is its own build because of the Qt ABI, and the asset name says which, e.g. `debian13-x86_64`.

### Open questions

- Where do tukzedo-linux's own defaults go? tukzedo could ship its own `/etc/xdg/lxqtukz/`, or this repo could keep them as a profile. Both work with the settings layers below.

- Should the rest of the LXQt apps be built here, or left to the distro? Right now only the desktop core and the terminal are pinned. The rest are lximage-qt, lxqt-archiver, screengrab and a few more.

- Release signing. Checksums are verified but nothing is signed yet. Probably minisign or sigstore on `sha256sums.txt`.

## Project structure

### Folder structure

- `upstream/`: what we track. `components.conf` has the pins, and `flags/<component>` has extra configure arguments.

- `patches/<component>/`: the patch queue for each component, as `NNNN-*.patch` files plus a `series` file.

- `source/`: LXQtukz's own files that go into the prefix. Session launcher, session entry, systemd units and default settings.
	- `source/settings/`: the settings app, `lxqtukz-settings`. Its design is in [design_docs/20260930-145721_settings-dialog.md](design_docs/20260930-145721_settings-dialog.md).

- `cicd/`: `upstream.bash` for tracking and patch queues, `build.bash` for the Debian build, `linux/Dockerfile` for the build container, and shared helpers in `utility/`, including `stage-prefix.bash`.
	- `settings.bash` checks the settings app and runs it on a headless Wayfire, in the test container from `linux/Dockerfile.test`. Last, on the host, it copies the release build to `~/.local/bin/lxqtukz-settings`. Only the latest is kept.
	- `paste.bash` checks copy and paste between apps on a headless Wayfire, using the release build's Wayfire and QTerminal, in the same container.
	- `session.bash` starts the release build's session on a headless Wayfire with its own session bus, in the same container. It checks that the wallpaper, D-Bus started services and the portal come from the prefix, that nothing starts pcmanfm-qt and Super+E opens the default file manager, and that the lock key and the idle lock lock the screen with gtklock.

- `nix/`: overlay, package and NixOS module. `flake.nix` is at the root.

- `install.bash`: the installer, which is also the updater once installed.

- `version`: the LXQtukz version, on one line.

- `work/`: local only, never committed. Upstream mirrors, patched trees and build dirs. Also the Debian prefix, in `work/prefix/<target>/<version>`, so `cicd/build.bash <component>` can rebuild one component into the last full build and stage it again.

- `project/`: design and backlog.

## Upstream tracking

### Why a patch queue

These 3 ways to keep changes on top of upstream were looked at.

- A vendored copy, edited in place. Easy to start with, but every upstream release turns into a big manual merge, and it gets hard to tell which lines are ours.

- A fork per component, merging upstream in. That's over 20 forks to keep in step, and merges bury our changes in history.

- A pinned upstream commit plus a patch series per component, rebased onto each new release. Our changes stay a short list of named patches that are easy to review. A bump is a rebase, done once per patch. Debian (gbp pq), Fedora and most distros manage their patches this way.

The last one was chosen. The queue is in this repo, so one commit can change a pin, its patches and the docs together, and every tag records all of them. If one component's queue ever turns into a real divergence, it can move to a fork under t00mietum. Its `url` changes and its queue empties, and nothing else has to change.

### Workflow

Everything goes through `cicd/upstream.bash`.

- `status`: the pin, how many patches, the newest upstream release, adn whether the work tree has changes not exported yet.
	- The newest release comes from the mirror, so it's as new as the last fetch. `--fetch` fetches first, and `--summary` prints only the closing 1-line summary, for the merge gate.

- `apply [component...]`: makes a bare mirror in `work/mirror/` and a work tree in `work/src/<component>` on branch `lxqtukz` at the pinned commit, then applies the queue with `git am`. It refuses to throw away a tree with commits that aren't in the queue yet.

- Edit by committing in the work tree. Use `git rebase -i` to reorder, split or reword. Each commit becomes one patch, and its message is the patch's description.

- `refresh <component>`: exports the work tree's commits back into `patches/<component>/`. The output is the same every time for the same commits, so a refresh with no real change gives no diff.

- `bump <component> <tag>`: fetches, applies, rebases the queue onto the new tag, updates the pin and refreshes. On a conflict it stops in the work tree. Fix it, run `git rebase --continue`, then `bump <component> --continue`.

`apply` also checks that the tag still points at the pinned commit, so an upstream tag that moved gets caught.

### Components

LXQt 2.4 and Wayfire 0.11.0 are pinned. Build order is the order of lines in `components.conf`.

- Wayfire 0.11 needs wlroots 0.20, and Debian 13 doesn't have it. So Wayfire builds its own pinned wlroots and wf-config submodules in, statically, per `upstream/flags/wayfire`. To patch wlroots, it would have to become its own component first.

- wlroots 0.20 also needs newer wayland, wayland-protocols, libdrm, xkbcommon and pixman than Debian 13 has. They're pinned as components too, built into the prefix right before Wayfire, with `-` in the `nix` column so NixOS keeps nixpkgs' own. Programs that link them directly load ours through the rpath, and each is backward compatible with what Debian's Qt, cairo and Mesa were built against. xkbcommon still reads the system's keymaps.

- pcmanfm-qt isn't built, so there's no file manager or desktop icons of our own. tukzdesk is the planned desktop and captain-nemo the planned file manager. Until then the desktop is the wallpaper swaybg draws, from Wayfire's `[autostart]`, and Super+E opens the home folder in the default file manager through `qtxdg-mat open`. On tukzedo Linux that default is Nemo Anywhere, until captain-nemo replaces it. libfm-qt is still built: lxqt-qtplugin's Qt file dialog and the portal's file chooser both use it.
	- A distro's pcmanfm-qt still has its own autostart entry in `/etc/xdg/autostart`, and the session reads `/etc/xdg` first. So on a box with one, lxqt-session starts its desktop.
	- lxqt-config's theme page starts `pcmanfm-qt --set-wallpaper` when "Override wallpaper" is checked. Without a pcmanfm-qt that does nothing.

- lxqt-qtplugin and libqtxdg put their Qt plugins in the prefix, under `lib/qt6/plugins`, rather than in Qt's own plugin dir. The session adds that dir to `QT_PLUGIN_PATH`.

- liblxqt's polkit action for the backlight helper goes in the prefix too, under `share/polkit-1/actions`. polkit never looks there, so the installer links it into `/usr/share/polkit-1/actions`. Its file name and id are the same as a distro LXQt's, and polkit keeps only one action per id, so the release renames it to `org.lxqtukz.backlight-<version>`. Each version's action names that version's helper, which is the one pkexec finds first on the session's `PATH`.

- `lxqt-wayland-session` is built for its Wayfire defaults (`lxqt-wayfire.ini`) and helper scripts. Its launcher is replaced by ours. The build checks that every plugin in that file's list is in the prefix.

- wf-shell, labwc and the other compositors aren't built. LXQt's panel is the shell.

## Configuration model

There are 2 settings areas, one for users and one for the system.

| Scope   | Directory                                          | Contents
| :---    | :---                                               | :---
| User    | `$XDG_CONFIG_HOME/lxqtukz/` (`~/.config/lxqtukz/`) | every LXQt module's `.conf`, `session.conf`, `wayfire.ini`, `gtklock.ini`
| System  | `/etc/xdg/lxqtukz/`                                | same file names, the admin's defaults, plus `update.conf`
| Release | `<prefix>/etc/xdg/lxqtukz/`                        | the defaults that come with each release

How it works:

- LXQt modules use `LXQt::Settings`, which is a `QSettings` with organization "lxqt". Qt looks for `$XDG_CONFIG_HOME/lxqt/<module>.conf` first, then `<dir>/lxqt/<module>.conf` in each `$XDG_CONFIG_DIRS` entry. Our first liblxqt patch takes that name from `LXQT_CONFIG_NAME`, and the session sets it to `lxqtukz`. When it's unset, stock LXQt works the same as before.

- The session puts `/etc/xdg` ahead of `<prefix>/etc/xdg` in `XDG_CONFIG_DIRS`. So an admin's file overrides the release's file of the same name, by the normal XDG lookup.

- `cicd/utility/stage-prefix.bash` builds the release defaults in layers. Upstream LXQt defaults go first, then upstream's `lxqt-wayfire.ini` as `wayfire.ini`, then our own files from `source/etc/xdg/lxqtukz/`. To change a default, either patch the upstream file if upstream might want the change, or add a file in `source/`.

- Wayfire reads only one file, with no layers. The session copies `~/.config/lxqtukz/wayfire.ini` into place once, from the admin's copy if there is one, else from the release. Admin changes after that don't reach existing users. A patch for layered Wayfire config is planned.

- A stock LXQt on the same machine keeps using `~/.config/lxqt/`.

Some components keep settings outside `LXQt::Settings` and aren't covered yet: libfm-qt, qterminal, and anything with plain `QSettings` or its own paths. They're in the backlog.

## Session

`startlxqtukz` replaces upstream's `startlxqtwayland`, which picks between several compositors. Ours only starts Wayfire.

- It works out its own prefix once, with `pwd -P`. On Debian that turns `/opt/lxqtukz/current/bin` into `/opt/lxqtukz/versions/<ver>`. Everything the session starts uses that path, so if an update switches `current` mid-session, the session still runs one version.

- It puts the prefix first in `PATH` and `XDG_DATA_DIRS`, so a distro LXQt never gets picked up by mistake. Libraries are found by rpath, without `LD_LIBRARY_PATH`.

- It sets the same Qt and XDG environment as upstream's launcher, plus `LXQT_CONFIG_NAME`, `XDG_SESSION_DESKTOP=lxqtukz` and `XDG_CURRENT_DESKTOP=LXQt:wayfire:wlroots`.

- It puts the prefix's D-Bus service files in the bus's runtime dir, `$XDG_RUNTIME_DIR/dbus-1/services`. A bus that systemd started before login only knows the service dirs it saw then, but it reads the runtime dir whenever a name it doesn't know is asked for. The `SystemdService=` line is dropped, since systemd can't see the units in the prefix, so the bus starts the program itself. For now that's only the LXQt portal.

- It hands `XDG_DATA_DIRS`, `XDG_CURRENT_DESKTOP` and a few more to D-Bus and the systemd user manager. Debian's `xdg-desktop-portal` runs as a systemd user service, and finds `lxqt.portal` and `lxqt-portals.conf` in the prefix through them. lxqt-session hands over the rest of the session's environment once Wayfire is up, but only to D-Bus.

- lxqt-session starts the portal as Qt starts up, before it hands over that environment. So the release's `wayfire.ini` hands `WAYLAND_DISPLAY` and `DISPLAY` to D-Bus and systemd on the `session` line, right before `lxqt-session`. Without it the LXQt portal finds no display and dies, and xdg-desktop-portal leaves its file chooser out for the rest of the session.

- It sets up the user's `wayfire.ini` with upstream's keyboard layout guess, then runs `exec wayfire -c` on it. Wayfire's `[autostart]` starts `lxqt-session`.

- Wayfire runs `[autostart]` lines through `sh`. So the wallpaper line in the release's `wayfire.ini` says `${LXQTUKZ_PREFIX}/share/lxqt/...`, and the user's copy keeps working after an update and a prune. `stage-prefix.bash` rewrites upstream's `/usr/share/lxqt/` paths that way, and fails if a `/usr` path is left for a file the prefix has.

- The notification daemon and the polkit agent aren't D-Bus started. lxqt-session starts them from the autostart entries in `<prefix>/etc/xdg/autostart`, by name, with the prefix first in `PATH`.

- The lock screen is gtklock. Upstream leaves LXQt's Wayland lock command empty, so nothing locked. The release's `session.conf` sets it to `lxqtukz-lock`, so the lock key, the panel, the leave dialog, and lxqt-session's lock before sleep all run that.
	- `lxqtukz-lock` runs `gtklock -d` with the first `gtklock.ini` it finds in the user, system and release settings areas. It returns once the screen is locked, which is when lxqt-session lets a suspend go ahead.
	- If gtklock is already running it does nothing. A second gtklock can't lock, and LXQt would show an error box for it.
	- The release's `wayfire.ini` starts swayidle, which runs `lxqt-leave --lockscreen` after an hour idle. That's when Wayfire's screensaver starts by default.
	- The user name comes from gtklock's userinfo module, which reads it from AccountsService.

## Install layout and versions

### Debian

- The prefix `/opt/lxqtukz/versions/<version>` is compiled in. LXQt and Wayfire both compile their install paths in, so a relocatable build would need path patches all over. A fixed path per version allows side-by-side versions without any of that.

- `/opt/lxqtukz/current` is a symlink to `versions/<version>`, and picks the active one. A switch makes the new link under a temp name with `ln -sfn`, then moves it into place with `mv -T`, so the switch is atomic.

- Integration points are symlinks through `current`, so a switch never has to touch them. They are `/usr/share/wayland-sessions/lxqtukz.desktop`, `/usr/local/bin/lxqtukz-update` and `/etc/systemd/system/lxqtukz-update.{service,timer}`.
	- The backlight helper's polkit actions are the exception. Every installed version gets its own link in `/usr/share/polkit-1/actions`, since a session runs the version it logged in with. Prune and uninstall remove them.
	- With `AUTO_UPDATE=no` the timer is disabled before its unit is linked. `systemctl disable` also removes a linked unit's own link.

- Qt, KF6 and system libraries come from Debian. Each release has a dependency list made at build time from the binaries' `NEEDED` entries, mapped to packages with `dpkg -S`. The installer apt-installs whatever is missing.

- `/var/lib/lxqtukz/history` records each switch with time, from, to and reason. Rollback reads it.

- There's no `.deb` for now. A package manager tracks one installed version of a package, and the point here is to have several side by side. A small `.deb` that only runs the installer could come later.

### NixOS

- The overlay reads the same `components.conf`, `flags/` and `patches/` as the Debian build. It overrides `src`, `version`, `patches` and configure flags for the nixpkgs LXQt scope and Wayfire. A change to a pin or a patch goes into both builds.

- `pkgs.lxqtukz` joins every component into one prefix with `symlinkJoin`, and runs the same `stage-prefix.bash`. So the layout and session launcher match Debian's.

- Versions are flake input revisions. A system flake follows `github:t00mietum/lxqtukz`, and `main` only gets releases, so that means "latest release".

- nixpkgs' own patches for a component are kept only while the nixpkgs version matches our pin. After that they're probably stale, and dropping them beats failing to apply them.

- The flake hasn't been built yet. That's milestone 2 in the backlog.

### Updater

`install.bash` is the web installer. Installed as `<prefix>/bin/lxqtukz-update`, it's also the updater, so installer and updater never drift apart.

- It gets the release list from the GitHub releases API, parsed without jq. The `stable` channel takes non-prerelease versions, and `dev` takes everything.

- The target is `--to` if given, else `PIN` from `update.conf`, else the newest on the channel. `--to` and `PIN` take any published version, so going down a version is the same as going up.

- On Debian it downloads, checks the release's `sha256sums.txt`, apt-installs missing dependencies, unpacks next to `versions/` and renames into place. Then it switches `current`, re-links the integration points and prunes.

- Prune keeps `KEEP` versions, 3 by default. It always keeps the active version, the rollback target, and any version a running process still has mapped.

- On NixOS it runs `nix flake lock --override-input lxqtukz github:t00mietum/lxqtukz/v<version>` on the system flake, then `nixos-rebuild boot`, or `switch` if configured.

- `--auto` is what the timer runs. It does nothing when `AUTO_UPDATE=no`, and never asks anything.

- `update.conf` is parsed as `KEY=value` and never sourced, since the updater runs as root.

Release assets. `cicd/build.bash` makes them and `install.bash` reads them, so change both together.

- `lxqtukz-<version>-<target>.tar.gz`: one top-level directory named `<version>`, which becomes `/opt/lxqtukz/versions/<version>`.

- `lxqtukz-<version>-<target>-deps.txt`: Debian package names, one per line.

- `lxqtukz-<version>-sha256sums.txt`: `sha256sum` format, for every target's archive and deps file.

## Delivery

Same model as nemo-anywhere. GitHub is for git hosting and release downloads, and the pipeline runs locally.

- Feature branches merge into `dev` with `--no-ff`. `main` only gets releases, by merging `dev` into it. Nothing is committed straight to `main`. That matters more here than usual, because NixOS users who follow the bare flake URL get whatever is on `main`.

- The version is in the `version` file. It only goes up on `main`, and each release is tagged `v<version>`.

- A release is `cicd/build.bash` per target, then a tag and a GitHub release with the assets above. The release notes are that version's changelog section. A version with a pre-release part, like `0.2.0-beta1`, is published as a prerelease, and only the `dev` channel picks it up.

- Releases are never deleted or replaced, because `--to` and `PIN` need old ones to stay put. A bad release gets replaced by a newer one.

- Still to bring over from nemo-anywhere: the `cicd.bash` stage engine and `config.bash`, the pre-push merge gate and version guard, `release.bash`, `changelog-notes.bash`, and backup and publish. They need fitting to this pipeline first, so they weren't copied as-is.

## Decisions along the way

- 2026-10-12: A patch queue was chosen over forks per component or a vendored tree. See [Why a patch queue](#why-a-patch-queue).

- 2026-10-12: A fixed prefix per version in `/opt` was chosen over a relocatable build or `.deb` packages. It allows side-by-side versions and atomic switching, without patching the paths LXQt and Wayfire compile in.

- 2026-10-12: Renaming the XDG config name to `lxqtukz` was chosen over symlinks or a private `XDG_CONFIG_HOME`.
	- A private `XDG_CONFIG_HOME` would move every app's settings in the session.
	- Symlinks would break a stock LXQt on the same machine.

- 2026-10-12: Our own session launcher was chosen over patching `startlxqtwayland`. Upstream's script is mostly about picking a compositor, which isn't wanted here.

- 2026-10-12: Wayfire's bundled wlroots was chosen over a system one, because no target distro has wlroots 0.20 yet.

- 2026-10-12: LGPL-2.1-or-later was chosen for our own desktop code because it matches LXQt, so code can move both ways without relicensing. Scripts are MIT, like the other t00mietum scripts.

- 2026-10-14: The settings app is Rust with a Qt Quick interface through cxx-qt, drawn by KDE's desktop style for Qt Quick. It keeps Rust and shcl, as in SilkTerm, and still follows the Qt theme like any other Qt app. Alternatives are in the settings design doc.

- 2026-10-14: LXQt stays the base rather than COSMIC, for now. tukzedo plans its own settings app, file manager, terminal and desktop layer, and maybe a panel, which leaves the base supplying the compositor and session plumbing. Wayfire's plugins and lxqt-qtplugin's theming of other Qt apps suit the personalities better than cosmic-comp, which is built for COSMIC's own shell.

- 2026-10-14: wayland, wayland-protocols, libdrm, xkbcommon and pixman were added to the Debian build for wlroots 0.20, over pinning an older Wayfire. The panel focus fix the paste workaround needs is only in Wayfire 0.11.

- 2026-10-14: D-Bus services from the prefix go through the bus's runtime dir rather than a system-wide `session.d` config. It needs no root, and other users and other desktops don't see our services, unless another desktop shares the bus with a running LXQtukz session.

- 2026-10-14: Wayfire's `focus_main_surface_instead_of_popup` workaround is on in the `wayfire.ini` that comes with each release. Without it, a Qt context menu's Paste pastes nothing that another app copied. It's a patch to upstream's file rather than our own copy, since LXQt upstream may want it too.

- 2026-10-15: fisheye is taken out of the release's Wayfire plugin list, rather than building wayfire-plugins-extra for it. A patch to upstream's `wayfire.ini` does it, like the paste and idle lock changes.

- 2026-10-15: gtklock is the screen locker. It's packaged for both Debian 13 and NixOS, and it shows a password box, "Login failed" for a wrong password, and with its userinfo module the user name. It needs ext-session-lock-v1, which is Wayfire's session-lock plugin, in Wayfire 0.11.

- 2026-10-15: pcmanfm-qt is out of the build, since tukzedo plans its own desktop (tukzdesk) and file manager (captain-nemo). Its patch for Debian's older layer-shell-qt went with it. libfm-qt stays, for the file dialogs.
