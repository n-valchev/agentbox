# Project source: mount exclude tests - feature disabled
# Tests: ME17
# Run: nix build .#checks.x86_64-linux.project-mount-excludes-disabled --print-build-logs
{ pkgs, self }:

let
  lib = import ./lib.nix { inherit pkgs self; };

  mockProject = lib.mkMockProject {
    marker = "flake.nix";
    extraFiles = {
      ".agentboxignore" = ".direnv";
      ".direnv/flake-profile" = "host-nix-store-path";
    };
  };
in
pkgs.testers.nixosTest {
  name = "agentbox-project-mount-excludes-disabled";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ self.nixosModules.default ];

    agentbox.vm.hostname = "test-vm";
    agentbox.user.name = "dev";
    agentbox.project.source.type = "mount";
    agentbox.project.source.required = true;
    agentbox.project.source.mount.exclude.enable = false;
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

    # ME17: Feature disabled via enable = false
    machine.fail("systemctl is-active shadow-mount-excludes.service")
    machine.succeed("test -f /home/dev/project/.direnv/flake-profile")
    machine.succeed("grep -q host-nix-store-path /home/dev/project/.direnv/flake-profile")
    print("ME17: Feature disabled via enable = false - PASSED")
  '';
}
