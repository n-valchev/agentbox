# Helper function to create a NixOS VM configuration
{ nixpkgs, nixpkgs-unstable ? null, gotha-nixpkgs ? null }:
{ hostSystem
, modules ? []
, extraConfig ? {}
}:
let
  # Map host system to guest VM system
  hostToGuest = {
    "aarch64-darwin" = "aarch64-linux";
    "x86_64-darwin" = "x86_64-linux";
    "aarch64-linux" = "aarch64-linux";
    "x86_64-linux" = "x86_64-linux";
  };

  guestSystem = hostToGuest.${hostSystem};
  hostPkgs = nixpkgs.legacyPackages.${hostSystem};

  # Get auggie package from gotha-nixpkgs if available
  gothaPkgs = if gotha-nixpkgs != null
    then gotha-nixpkgs.packages.${guestSystem}
    else {};

  # Unstable packages for getting latest versions (with unfree allowed)
  unstablePkgs = if nixpkgs-unstable != null
    then import nixpkgs-unstable { system = guestSystem; config.allowUnfree = true; }
    else null;

in
nixpkgs.lib.nixosSystem {
  system = guestSystem;
  modules = [
    # QEMU VM support
    ({ modulesPath, ... }: {
      imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];
      virtualisation.host.pkgs = hostPkgs;
    })

    # Allow unfree software
    ({ ... }: {
      nixpkgs.config.allowUnfree = true;
    })

    # The main devenv module
    ../modules

    # User-provided extra configuration
    extraConfig
  ] ++ modules;

  specialArgs = {
    inherit hostPkgs hostSystem gothaPkgs unstablePkgs;
  };
}

