## Joins every component into one prefix, then finishes it with the same stage
## script the Debian build uses, so both installs have the same layout and the
## same session launcher logic.
{ lib, symlinkJoin, bash, src, version, commit, components }:

symlinkJoin {
  name = "lxqtukz-${version}";
  paths = components;

  postBuild = ''
    ${bash}/bin/bash ${src}/cicd/utility/stage-prefix.bash "$out" "$out" ${lib.escapeShellArg version} ${lib.escapeShellArg commit} nixos
  '';

  passthru.providedSessions = [ "lxqtukz" ];

  meta = {
    description = "LXQt desktop on the Wayfire compositor";
    homepage = "https://github.com/tukzedo/lxqtukz";
    license = lib.licenses.lgpl21Plus;
    platforms = lib.platforms.linux;
  };
}
