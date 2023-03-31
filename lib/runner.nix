{ pkgs
, microvmConfig
, kernel ? pkgs.callPackage ../pkgs/microvm-kernel.nix {
    inherit (pkgs.linuxPackages_latest) kernel;
  }
, bootDisk
, toplevel
}:

let
  inherit (pkgs) lib writeScriptBin;

  inherit (import ./. { nixpkgs-lib = lib; }) createVolumesScript makeMacvtap;
  inherit (makeMacvtap microvmConfig) openMacvtapFds macvtapFds;

  hypervisorConfig = import (./runners + "/${microvmConfig.hypervisor}.nix") {
    inherit pkgs microvmConfig kernel bootDisk macvtapFds;
  };

  inherit (hypervisorConfig) command canShutdown shutdownCommand;
  preStart = hypervisorConfig.preStart or microvmConfig.preStart;

  runScriptBin = pkgs.writeScriptBin "microvm-run" ''
    #! ${pkgs.runtimeShell} -e

    ${preStart}
    ${createVolumesScript pkgs microvmConfig.volumes}
    ${lib.optionalString (hypervisorConfig.requiresMacvtapAsFds or false) openMacvtapFds}

    exec ${command}
  '';

  shutdownScriptBin = pkgs.writeScriptBin "microvm-shutdown" ''
    #! ${pkgs.runtimeShell} -e

    ${shutdownCommand}
  '';

  balloonScriptBin = pkgs.writeScriptBin "microvm-balloon" ''
    #! ${pkgs.runtimeShell} -e

    if [ -z "$1" ]; then
      echo "Usage: $0 <balloon-size-mb>"
      exit 1
    fi

    SIZE=$1
    ${hypervisorConfig.setBalloonScript}
  '';
in

pkgs.runCommand "microvm-${microvmConfig.hypervisor}-${microvmConfig.hostName}"
{
  # for `nix run`
  meta.mainProgram = "microvm-run";
  passthru = {
    inherit canShutdown;
  };
} ''
  mkdir -p $out/bin

  ln -s ${runScriptBin}/bin/microvm-run $out/bin/microvm-run
  ${if canShutdown
    then "ln -s ${shutdownScriptBin}/bin/microvm-shutdown $out/bin/microvm-shutdown"
    else ""}
  ${lib.optionalString ((hypervisorConfig.setBalloonScript or null) != null) ''
    ln -s ${balloonScriptBin}/bin/microvm-balloon $out/bin/microvm-balloon
  ''}

  mkdir -p $out/share/microvm
  ln -s ${toplevel} $out/share/microvm/system

  ${lib.concatMapStringsSep " " (interface:
    lib.optionalString (interface.type == "tap" && interface ? id) ''
      echo "${interface.id}" >> $out/share/microvm/tap-interfaces
    '') microvmConfig.interfaces}

  ${lib.concatMapStringsSep " " (interface:
    lib.optionalString (interface.type == "macvtap" && interface ? id  && interface ? macvtap && interface.macvtap ? link) ''
      echo "${builtins.concatStringsSep " " [
        interface.id
        interface.mac
        interface.macvtap.link
        (builtins.toString interface.macvtap.mode)
      ]}" >> $out/share/microvm/macvtap-interfaces
    '') microvmConfig.interfaces}


  ${lib.concatMapStrings ({ tag, socket, source, proto, ... }:
      lib.optionalString (proto == "virtiofs") ''
        mkdir -p $out/share/microvm/virtiofs/${tag}
        echo "${socket}" > $out/share/microvm/virtiofs/${tag}/socket
        echo "${source}" > $out/share/microvm/virtiofs/${tag}/source
      ''
    ) microvmConfig.shares}

  ${lib.concatMapStrings ({ bus, path, ... }: ''
    echo "${path}" >> $out/share/microvm/${bus}-devices
  '') microvmConfig.devices}
''