# Claude Code configuration module
{ config, lib, pkgs, unstablePkgs ? null, ... }:
let
  cfg = config.agentbox.claudecode;
  claudeCodePkg = if unstablePkgs != null then unstablePkgs.claude-code else pkgs.claude-code;
in
{
  options.agentbox.claudecode = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Claude Code package";
    };

    syncConfigFromHost = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description =
        "Copy Claude Code configuration from host ~/.claude to guest";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ claudeCodePkg ];

    agentbox.hostShares = lib.mkIf cfg.syncConfigFromHost [{
      tag = "host-claude-code";
      hostPath = ".claude";
      dest = ".claude";
      mode = "700";
      fileOverrides = [ ];
    }];
  };
}

