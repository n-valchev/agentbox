# Project source: mount exclude tests (core)
# Tests: ME1-ME5, ME8-ME10
# Run: nix build .#checks.x86_64-linux.project-mount-excludes --print-build-logs
{ pkgs, self }:

let
  lib = import ./lib.nix { inherit pkgs self; };

  # Mock project with .agentboxignore and excludable paths
  mockProject = lib.mkMockProject {
    marker = "flake.nix";
    extraFiles = {
      ".agentboxignore" = builtins.concatStringsSep "\n" [
        "# Host-specific Nix artifacts"
        ".direnv"
        "result"
        ""
        "# Host-native binaries"
        "node_modules"
        ""
        "# Pre-shadow a path that does not exist on the host yet"
        "nonexistent"
      ];
      ".direnv/flake-profile" = "host-nix-store-path";
      ".direnv/flake-inputs" = "host-inputs";
      "result" = "host-build-output";
      "node_modules/package/index.js" = "module.exports = {}";
    };
  };
in
pkgs.testers.nixosTest {
  name = "agentbox-project-mount-excludes";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ self.nixosModules.default ];

    agentbox.vm.hostname = "test-vm";
    agentbox.user.name = "dev";
    agentbox.project.source.type = "mount";
    agentbox.project.source.required = true;
    agentbox.project.destPath = "/home/dev/project";
    agentbox.project.marker = "flake.nix";
    agentbox.project.validateMarker = true;

    virtualisation.sharedDirectories.host-project = {
      source = "${mockProject}";
      target = "/home/dev/project";
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("mount-host-project.service")
    machine.wait_for_unit("shadow-mount-excludes.service")

    # ME1: Exclude directory via .agentboxignore
    machine.succeed("test -d /home/dev/project/.direnv")
    machine.fail("test -f /home/dev/project/.direnv/flake-profile")
    machine.succeed("test -f /home/dev/project/flake.nix")
    machine.succeed("test -f /home/dev/project/README.md")
    machine.succeed("test -f /home/dev/project/src/index.js")
    print("ME1: Exclude directory via .agentboxignore - PASSED")

    # ME2: Exclude multiple paths
    machine.succeed("test -d /home/dev/project/.direnv")
    machine.fail("test -f /home/dev/project/.direnv/flake-profile")
    machine.succeed("test -e /home/dev/project/result")
    machine.fail("grep -q host-build-output /home/dev/project/result")
    machine.succeed("test -d /home/dev/project/node_modules")
    machine.fail("test -f /home/dev/project/node_modules/package/index.js")
    print("ME2: Exclude multiple paths - PASSED")

    # ME3: Exclude a file
    machine.succeed("test -e /home/dev/project/result")
    machine.succeed("test ! -s /home/dev/project/result")
    print("ME3: Exclude a file - PASSED")

    # ME4: Excluded path is writable by VM
    machine.succeed("sudo -u dev touch /home/dev/project/.direnv/test-file")
    machine.succeed("test -f /home/dev/.local/shadow/.direnv/test-file")
    print("ME4: Excluded path is writable by VM - PASSED")

    # ME5: Non-excluded paths are unaffected
    machine.succeed("sudo -u dev cat /home/dev/project/flake.nix")
    machine.succeed("sudo -u dev cat /home/dev/project/src/index.js")
    machine.succeed("grep -q hello /home/dev/project/src/index.js")
    print("ME5: Non-excluded paths are unaffected - PASSED")

    # ME9: Path does not exist on host - pre-shadowed as empty directory
    machine.succeed("test -d /home/dev/project/nonexistent")
    machine.succeed("mountpoint -q /home/dev/project/nonexistent")
    machine.succeed("sudo -u dev touch /home/dev/project/nonexistent/test-file")
    machine.succeed("test -f /home/dev/.local/shadow/nonexistent/test-file")
    print("ME9: Path does not exist on host - PASSED")

    # ME8: Comments and blank lines in ignore file
    machine.succeed("mountpoint -q /home/dev/project/.direnv")
    machine.succeed("mountpoint -q /home/dev/project/result")
    machine.succeed("mountpoint -q /home/dev/project/node_modules")
    machine.succeed("mountpoint -q /home/dev/project/nonexistent")
    machine.fail("mountpoint -q /home/dev/project/src")
    print("ME8: Comments and blank lines in ignore file - PASSED")

    # ME10: Service restart re-applies mounts correctly
    machine.succeed("systemctl restart shadow-mount-excludes.service")
    machine.succeed("mountpoint -q /home/dev/project/.direnv")
    machine.succeed("mountpoint -q /home/dev/project/result")
    machine.succeed("mountpoint -q /home/dev/project/node_modules")
    machine.succeed("mountpoint -q /home/dev/project/nonexistent")
    machine.succeed("test -f /home/dev/.local/shadow/.direnv/test-file")
    machine.succeed("test -f /home/dev/.local/shadow/nonexistent/test-file")
    print("ME10: Service restart re-applies mounts correctly - PASSED")

    print("All core project-mount-excludes tests passed!")
  '';
}
