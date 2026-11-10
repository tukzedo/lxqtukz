# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
## vNEXT - DATE

### Notes

### Upstream

### Added

### Changed

### Removed

### Other work
-->

## v0.1.0-alpha1 - unreleased

### Notes

- First release line. Nothing published yet.

### Upstream

- LXQt 2.4.0 (lxqt-panel 2.4.1), libqtxdg 4.4.0, lxqt-wayland-session 0.4.1, Wayfire 0.11.0.

### Added

- liblxqt: settings directory name taken from `LXQT_CONFIG_NAME`, so all of LXQtukz's settings live in `~/.config/lxqtukz/` and `/etc/xdg/lxqtukz/`.

- `startlxqtukz` session launcher for LXQt on Wayfire.

- `install.bash` / `lxqtukz-update`: install, update, switch to any version, roll back, on Debian 13 and NixOS.

- NixOS flake with an overlay and a `services.lxqtukz` module.

- `lxqtukz-settings`, a settings app, with screen power and screensaver, keyboard, and mouse and touchpad tabs. Debian build only for now.

### Changed

- Wayfire's fisheye plugin is out of the release's plugin list. It's in wayfire-plugins-extra, which isn't built.

- The backlight helper's polkit action has its own name per version, and the installer links it where polkit reads it.

- Super+E opens the home folder in whatever file manager is the default. Super+P used to start pcmanfm-qt.

- The workspace overview moved from Super+E to Super+W.

### Removed

- pcmanfm-qt isn't built. So there are no desktop icons for now, only the wallpaper. libfm-qt is still built, for the Qt file dialog and the portal's file chooser.

### Other work

- Upstream tracking and patch-queue tooling (`cicd/upstream.bash`).

- Debian 13 container build (`cicd/build.bash`).

- Settings app checks and keyboard tests on a headless Wayfire (`cicd/settings.bash`).

- Installer checks in a Debian 13 container (`cicd/installer.bash`).

- `cicd/build.bash dogfood`: a full build, then installed on the box it was built on.

- `cicd/upstream.bash status --fetch` and `--summary`.

- Checks for the cicd scripts themselves (`cicd/tooling.bash`).
