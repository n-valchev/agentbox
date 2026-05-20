# Service to shadow excluded paths with VM-local bind mounts
# Only active when source.type = "mount" and mount.exclude.enable = true
# Reads the ignore file at runtime from the mounted project
# Automatically reloads when the ignore file changes
{ config, lib, pkgs, ... }:
let
  cfg = config.agentbox;
  projectCfg = cfg.project;
  excludeCfg = projectCfg.source.mount.exclude;
  isMount = projectCfg.source.type == "mount";
  isEnabled = isMount && excludeCfg.enable;

  destPath = projectCfg.destPath;
  ignoreFile = excludeCfg.ignoreFile;
  shadowBase = "${cfg.user.home}/.local/shadow";
  userName = cfg.user.name;

  # Python script to resolve excluded paths using pathspec
  resolveExcludes = pkgs.writeScript "resolve-excludes" ''
    #!${pkgs.python3.withPackages (ps: [ ps.pathspec ])}/bin/python3
    import pathspec, sys, os

    ignore_file = sys.argv[1]
    project_root = sys.argv[2]

    with open(ignore_file) as f:
        lines = f.readlines()

    # Warn about and strip path traversal patterns before matching.
    # Also collect literal (non-glob, non-negation, top-level) patterns so we
    # can pre-shadow paths that don't exist yet on the host.
    safe_lines = []
    literal_patterns = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith('#'):
            parts = stripped.lstrip('!').split('/')
            if '..' in parts:
                print(f"WARNING: skipping path outside project: {stripped}", file=sys.stderr)
                continue
            if not stripped.startswith('!') and not any(c in stripped for c in '*?['):
                candidate = stripped.rstrip('/')
                if '/' not in candidate:
                    literal_patterns.append(candidate)
        safe_lines.append(line)

    spec = pathspec.PathSpec.from_lines("gitwildmatch", safe_lines)

    # Emit entries that exist and match
    for entry in sorted(os.listdir(project_root)):
        if spec.match_file(entry):
            print(entry)

    # Emit literal patterns for paths that don't exist yet
    for entry in sorted(set(literal_patterns)):
        if not os.path.lexists(os.path.join(project_root, entry)):
            print(entry)
  '';
in
{
  config = lib.mkIf isEnabled {
    systemd.services.shadow-mount-excludes = {
      description = "Shadow excluded paths with VM-local bind mounts";
      wantedBy = [ "multi-user.target" ];

      after = [ "mount-host-project.service" ];
      requires = [ "mount-host-project.service" ];
      before = [ "multi-user.target" ];

      path = [ pkgs.coreutils pkgs.util-linux ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail

        SHADOW_BASE="${shadowBase}"
        PROJECT="${destPath}"
        IGNORE_FILE="$PROJECT/${ignoreFile}"

        if [ ! -f "$IGNORE_FILE" ]; then
          echo "No ignore file found at $IGNORE_FILE, skipping"
          exit 0
        fi

        install -d -o ${userName} -g users "$SHADOW_BASE"

        # Unmount any stale shadow mounts no longer in the ignore file
        CURRENT_MOUNTS=$(findmnt --submounts "$PROJECT" -n -o TARGET 2>/dev/null || true)
        NEW_EXCLUDES=$(${resolveExcludes} "$IGNORE_FILE" "$PROJECT" || true)

        for mount_target in $CURRENT_MOUNTS; do
          # Only consider mounts whose source is under SHADOW_BASE
          mount_source=$(findmnt -n -o SOURCE "$mount_target" 2>/dev/null || true)
          case "$mount_source" in
            "$SHADOW_BASE"/*) ;;
            *) continue ;;
          esac

          rel_path="''${mount_target#$PROJECT/}"
          still_excluded=false
          for entry in $NEW_EXCLUDES; do
            if [ "$entry" = "$rel_path" ]; then
              still_excluded=true
              break
            fi
          done
          if [ "$still_excluded" = false ]; then
            echo "Unmounting stale shadow: $rel_path"
            umount "$mount_target" || echo "WARNING: failed to unmount $mount_target"
          fi
        done

        # Track excluded parents for deduplication
        EXCLUDED_PARENTS=""

        for entry in $NEW_EXCLUDES; do
          TARGET="$PROJECT/$entry"
          SHADOW="$SHADOW_BASE/$entry"

          # Validate path stays within project
          REAL_TARGET="$(realpath -m "$TARGET")"
          case "$REAL_TARGET" in
            "$PROJECT"/*) ;;
            *) echo "WARNING: skipping path outside project: $entry"; continue ;;
          esac

          # Skip children of already-excluded parents
          skip=false
          for parent in $EXCLUDED_PARENTS; do
            case "$entry" in
              "$parent"/*) skip=true; break ;;
            esac
          done
          if [ "$skip" = true ]; then
            echo "Skipping nested path (parent already excluded): $entry"
            continue
          fi

          # Skip if already mounted (idempotency)
          if mountpoint -q "$TARGET" 2>/dev/null; then
            echo "Already shadowed: $entry"
            EXCLUDED_PARENTS="$EXCLUDED_PARENTS $entry"
            continue
          fi

          if [ -d "$TARGET" ]; then
            echo "Shadowing directory: $entry"
            install -d -o ${userName} -g users "$SHADOW"
            mount --bind "$SHADOW" "$TARGET"
          elif [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
            echo "Shadowing file: $entry"
            install -d -o ${userName} -g users "$(dirname "$SHADOW")"
            touch "$SHADOW"
            chown ${userName}:users "$SHADOW"
            mount --bind "$SHADOW" "$TARGET"
          else
            echo "Shadowing new path (as directory): $entry"
            install -d -o ${userName} -g users "$SHADOW"
            mkdir -p "$TARGET"
            mount --bind "$SHADOW" "$TARGET"
          fi

          EXCLUDED_PARENTS="$EXCLUDED_PARENTS $entry"
        done
      '';
    };

    # Watcher: auto-reload when ignore file changes
    systemd.paths.shadow-mount-excludes-watcher = {
      description = "Watch ignore file for changes";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathModified = "${destPath}/${ignoreFile}";
      };
    };

    systemd.services.shadow-mount-excludes-watcher = {
      description = "Reload shadow mounts after ignore file change";
      after = [ "shadow-mount-excludes.service" ];

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
        echo "Ignore file changed, reloading shadow mounts..."
        systemctl restart shadow-mount-excludes.service
      '';
    };
  };
}
