# Library functions for the development VM flake
{ nixpkgs, nixpkgs-unstable ? null, gotha-nixpkgs ? null }:
{
  # Create a VM configuration for a specific host system
  mkDevVm = import ./mk-dev-vm.nix { inherit nixpkgs nixpkgs-unstable gotha-nixpkgs; };

  # Create wrapper scripts for running the VM
  mkVmRunner = import ./mk-vm-runner.nix;

  # Generate apps from nixosConfigurations (eliminates boilerplate in consumer flakes)
  mkVmApps = import ./mk-vm-apps.nix { inherit nixpkgs; };
}

