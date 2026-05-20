# Project source: mount exclude tests - custom ignore file, glob, nested, traversal
# Tests: ME7, ME13, ME14, ME15
# Run: nix build .#checks.x86_64-linux.project-mount-excludes-custom --print-build-logs
{ pkgs, self }:

let
  lib = import ./lib.nix { inherit pkgs self; };

  mockProject = lib.mkMockProject {
    marker = "flake.nix";
    extraFiles = {
      ".myignore" = builtins.concatStringsSep "\n" [
        ".direnv"
        ".dir*"
        "node_modules"
        "node_modules/sharp"
        "../etc/passwd"
      ];
      ".direnv/flake-profile" = "host-nix-store-path";
      ".dirother/data" = "other-data";
      "node_modules/package/index.js" = "module.exports = {}";
      "node_modules/sharp/lib.js" = "native code";
    };
  };
in
pkgs.testers.nixosTest {
  name = "agentbox-project-mount-excludes-custom";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ self.nixosModules.default ];

    agentbox.vm.hostname = "test-vm";
    agentbox.user.name = "dev";
    agentbox.project.source.type = "mount";
    agentbox.project.source.required = true;
    agentbox.project.source.mount.exclude.ignoreFile = ".myignore";
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
    machine.wait_for_unit("shadow-mount-excludes.service")

    # ME7: Custom ignore file name - reads from .myignore
    machine.succeed("mountpoint -q /home/dev/project/.direnv")
    machine.fail("test -f /home/dev/project/.direnv/flake-profile")
    print("ME7: Custom ignore file name - PASSED")

    # ME13: Path traversal attempt is warned and skipped
    machine.fail("mountpoint -q /etc/passwd")
    machine.succeed("journalctl -u shadow-mount-excludes.service --no-pager | grep -q 'skipping path outside project'")
    print("ME13: Path traversal attempt is warned and skipped - PASSED")

    # ME14: Nested paths are deduplicated (node_modules/sharp is not a top-level entry,
    # so pathspec never outputs it; only node_modules is shadowed)
    machine.succeed("mountpoint -q /home/dev/project/node_modules")
    machine.fail("mountpoint -q /home/dev/project/node_modules/sharp")
    print("ME14: Nested paths are deduplicated - PASSED")

    # ME15: Gitignore glob patterns work
    machine.succeed("mountpoint -q /home/dev/project/.direnv")
    machine.succeed("mountpoint -q /home/dev/project/.dirother")
    machine.fail("test -f /home/dev/project/.dirother/data")
    print("ME15: Gitignore glob patterns work - PASSED")

    print("All custom project-mount-excludes tests passed!")
  '';
}
