# Services module - imports all systemd services
{ ... }:
{
  imports = [
    ./host-config-sync.nix
    ./host-project-mount.nix
    ./host-project-copy.nix
    ./host-project-git.nix
    ./shadow-mount-excludes.nix
  ];
}

