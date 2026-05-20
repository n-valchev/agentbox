# Project source: mount exclude tests - no ignore file
# Tests: ME6
# Run: nix build .#checks.x86_64-linux.project-mount-excludes-noignore --print-build-logs
{ pkgs, self }:

let
  lib = import ./lib.nix { inherit pkgs self; };
  mockProject = lib.mkMockProject { marker = "flake.nix"; };
in
pkgs.testers.nixosTest {
  name = "agentbox-project-mount-excludes-noignore";

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
    machine.wait_for_unit("shadow-mount-excludes.service")

    # ME6: No ignore file (backward compat) - service is a no-op
    machine.succeed("test -f /home/dev/project/flake.nix")
    machine.succeed("test -f /home/dev/project/README.md")
    machine.succeed("test ! -d /home/dev/.local/shadow")
    print("ME6: No ignore file (backward compat) - PASSED")
  '';
}
