# Default configuration values for the development VM
# These can be overridden via module options in consuming flakes
{
  # VM Resources
  vm = {
    cores = 4;
    memorySize = 8192;  # MB
    diskSize = 50000;   # MB
    hostname = "dev-vm";
  };

  # Primary user configuration
  user = {
    name = "dev";
    home = "/home/dev";
    extraGroups = [ "wheel" ];
  };

  # Network configuration
  networking = {
    ports = [ 22 ];  # Base ports, projects add their own
    ssh = {
      enable = true;
      permitRootLogin = "no";
      passwordAuth = true;
    };
  };

  # Host shares to sync into VM on boot
  # Projects should override this with their specific needs
  hostShares = [];

  # Project source configuration
  project = {
    source = {
      type = "mount";        # "mount" | "copy" | "git"
      path = null;           # Auto-detect via marker if null
      refresh = "if-missing"; # "always" | "if-missing"
      required = true;       # Fail boot if source setup fails
      git = {
        url = null;
        ref = null;          # Use repo's default branch if null
        shallow = false;     # Full clone by default
        depth = 1;
      };
      copy = {
        excludePatterns = []; # Empty by default, user must specify
      };
      mount = {
        exclude = {
          enable = true;        # Enable shadow bind-mounts for excluded paths
          ignoreFile = ".agentboxignore"; # Ignore file relative to project root
        };
      };
    };
    destPath = "/home/dev/project";
    marker = "flake.nix";    # File that identifies project root
    validateMarker = true;   # Validate marker exists
  };

  # Environment variables
  environment = {
    editor = "vim";
    variables = {};
  };

  # Development tools
  development = {
    nix = {
      enableFlakes = true;
    };
    direnv = {
      enable = true;
      whitelist = [ "/home/dev/project" ];
    };
    git = {
      safeDirectories = [ "/home/dev/project" "*" ];
    };
  };

}

