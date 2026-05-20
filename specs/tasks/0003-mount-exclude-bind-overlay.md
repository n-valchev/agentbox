# Mount Exclude via Bind-Mount Overlay

## Overview

Add an `exclude` option to the mount source method that reads an ignore file (like `.gitignore`) from the project root and shadows matching paths with VM-local bind mounts. This allows users to hide host paths that are incompatible with the guest (e.g., `.direnv` containing darwin Nix store paths when the guest is Linux) while keeping the rest of the project live-synced via 9p.

## Problem

The mount source method shares the entire project directory via 9p virtfs. There is no way to selectively exclude paths. Some paths contain host-specific artifacts that are incompatible with the guest OS:

- `.direnv/` — contains Nix store paths built for the host platform (e.g., darwin). These paths are invalid inside a Linux VM
- `result` — Nix build output symlink pointing to host store paths
- `node_modules/` — may contain native binaries compiled for the host architecture

Currently, the only workaround is to use the `copy` source method with `excludePatterns`, but this sacrifices live two-way sync.

## Goals

- Allow mount-mode users to exclude specific paths from the guest's view
- Support both files and directories
- Use a file-based ignore format (like `.gitignore`) so excludes live in the project, not in Nix config
- Support gitignore-compatible pattern syntax (globs, comments, blank lines) via Python `pathspec`
- Allow configuring which ignore file to read (e.g., reuse `.gitignore` instead of a separate file)
- Preserve live read-write sync for all non-excluded paths
- Host paths are never modified — excludes only affect the guest's view
- Excluded paths get VM-local storage that persists across the mount session
- Automatically reload when the ignore file changes (no VM restart required)

## Non-Goals

- Modifying the 9p mount mechanism itself
- Deep recursive pattern matching (e.g., `**/*.pyc`) — patterns match against top-level project entries only, because bind-mounts operate on discrete path prefixes

## Design

### Ignore file format

The ignore file uses gitignore-compatible syntax, parsed by Python `pathspec` (the `gitwildmatch` pattern style). Patterns are matched against **top-level entries** in the project root only — deep patterns like `src/**/*.tmp` are not supported because bind-mounts cannot target individual files scattered across a tree.

Supported syntax:
- One pattern per line
- `#` comments (full-line only)
- Blank lines are ignored
- Glob patterns: `*`, `?`, `[abc]`
- Trailing `/` to match directories only
- Negation with `!` prefix

Example `.agentboxignore`:
```
# Host-specific Nix artifacts
.direnv
result

# Host-native binaries
node_modules
```

The user can point to a different file (e.g., `.gitignore`) via the `ignoreFile` option. When using `.gitignore`, be aware that only top-level entries are matched — deep patterns are silently ignored.

### Approach: Post-mount bind-mount overlay

After the 9p mount completes, a new systemd service (`shadow-mount-excludes`) reads the ignore file from the mounted project and bind-mounts VM-local paths over each matching entry. This effectively "shadows" the host paths — they still exist on the 9p mount but are hidden by the bind-mount.

```
Step 1: 9p mount (existing behavior, unchanged)
  host:/path/to/project → /home/dev/project
  All files visible including .direnv, result, node_modules

Step 2: shadow-mount-excludes service (new)
  Reads /home/dev/project/.agentboxignore
  Enumerates top-level entries via os.listdir
  Filters through pathspec gitwildmatch
  For each matched entry:
    If directory:
      install -d -o dev -g users /home/dev/.local/shadow/<path>
      mount --bind /home/dev/.local/shadow/<path> /home/dev/project/<path>
    If file:
      install -d -o dev -g users /home/dev/.local/shadow/$(dirname <path>)
      touch /home/dev/.local/shadow/<path> && chown dev:users ...
      mount --bind /home/dev/.local/shadow/<path> /home/dev/project/<path>

Result:
  /home/dev/project/.direnv  → VM-local (empty dir, not host's darwin paths)
  /home/dev/project/result   → VM-local (empty file, not host's symlink)
  /home/dev/project/src/     → host (live, read-write via 9p)
```

The host's original paths are untouched. Inside the VM, the excluded paths point to empty local storage where the VM can write its own content (e.g., the VM's direnv can populate `.direnv` with Linux-native Nix store paths).

### Idempotency

The service must be safe to run multiple times (on restart or reload). Before applying each bind-mount, it checks `mountpoint -q` to skip paths that are already shadowed. On reload, it first unmounts any stale shadow mounts (paths that were previously shadowed but are no longer in the ignore file) before applying new ones.

### Automatic reload on ignore file change

A companion `shadow-mount-excludes-watcher.path` systemd unit watches the ignore file for changes. When the file is modified, it triggers a reload of the shadow service — no VM restart needed. The idempotent design ensures reloads are safe.

### Path validation

The ignore file is read from user-controlled content on the host. To prevent unexpected bind-mounts outside the project directory, every resolved path is validated:

```bash
REAL_TARGET="$(realpath -m "$TARGET")"
case "$REAL_TARGET" in
  "$PROJECT"/*) ;; # OK
  *) echo "WARNING: skipping path outside project: $entry"; continue ;;
esac
```

Paths that escape the project root (e.g., `../../etc/passwd`) are logged with a warning and skipped.

### Nested path deduplication

If multiple patterns match nested paths (e.g., `node_modules` and `node_modules/sharp`), children of already-shadowed parents are skipped. Entries are sorted by depth and tracked; a child whose parent is already bind-mounted is logged and skipped to avoid stacking mounts.

### File vs directory detection

The service checks the type of each path on the mounted project directory:
- If the path exists and is a directory → shadow with a directory bind-mount
- If the path exists and is a file (or symlink) → shadow with a file bind-mount
- If the path does not exist → default to directory (create and shadow as a directory)

### Disk usage tradeoff

Shadowed paths use VM-local storage at `~/.local/shadow/`, which lives on the VM's virtio-blk disk (default 50GB via `diskSize`). If a shadowed path like `node_modules` accumulates large amounts of data inside the VM, it consumes VM disk space. Users with large excluded directories should size `diskSize` accordingly.

### Why bind-mount?

| Alternative | Why not |
|-------------|---------|
| Modify 9p to support excludes | 9p protocol has no exclude mechanism |
| overlayfs over 9p | overlayfs on top of 9p has known kernel issues and adds complexity |
| Unmount + remount subfolder | 9p doesn't support per-subdirectory mounts |
| Use copy method instead | Loses live two-way sync |
| Symlink tricks | Doesn't hide the host path contents |

Bind-mount is a standard Linux kernel feature, well-tested, and does exactly what we need: replace the view of a path without modifying the underlying mount. Bind-mounts have zero runtime performance overhead — they're a VFS-level redirect, not a data copy.

### Difference from `copy` method's `excludePatterns`

The `copy` method has its own `excludePatterns` option that uses rsync `--exclude` format at copy time. The `mount` method's `ignoreFile` is a different mechanism: runtime bind-mount overlays read from a project-side file. These are not interchangeable. If switching from `copy` to `mount`, users must create an `.agentboxignore` (or point `ignoreFile` to `.gitignore`) — `copy.excludePatterns` is not consulted.

## Configuration

### New options

```nix
options.agentbox.project.source.mount = {
  exclude = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to enable shadow bind-mounts for excluded paths.
        Set to false to disable even if an ignore file exists.
        Only applies when source.type = "mount".
      '';
    };

    ignoreFile = lib.mkOption {
      type = lib.types.str;
      default = ".agentboxignore";
      description = ''
        Name of the ignore file (relative to project root) listing paths to
        shadow with VM-local bind mounts. Uses gitignore-compatible syntax
        parsed by Python pathspec (gitwildmatch). Patterns match against
        top-level project entries only.
        Set to an alternative like ".gitignore" to reuse existing ignore files.
        Only applies when source.type = "mount".
      '';
      example = ".gitignore";
    };
  };
};
```

### Usage

Default — uses `.agentboxignore` in the project root:
```nix
agentbox.project = {
  source.type = "mount";
  # No config needed — reads .agentboxignore by default
};
```

Reuse `.gitignore`:
```nix
agentbox.project = {
  source.type = "mount";
  source.mount.exclude.ignoreFile = ".gitignore";
};
```

Disable shadow mounts entirely:
```nix
agentbox.project = {
  source.type = "mount";
  source.mount.exclude.enable = false;
};
```

### Project-side `.agentboxignore`

```
# Nix artifacts (host-specific)
.direnv
result

# Native binaries
node_modules
```

### Default behavior

If the ignore file does not exist in the project, the service is a no-op (no excludes applied). This is fully backward compatible — existing projects without an `.agentboxignore` file are unaffected.

If `source.mount.exclude.enable = false`, the shadow service and watcher are not activated regardless of whether an ignore file exists.

## Implementation

### New dependency: `python3Packages.pathspec`

Add `pathspec` to the VM's packages for gitignore-compatible pattern parsing:

```nix
path = [ pkgs.coreutils pkgs.util-linux pkgs.python3Packages.pathspec ];
```

`pathspec` is a pure Python package (~500 lines, no C deps), well-maintained, and used by Black, isort, mypy, and other major tools. It provides exact gitignore semantics via the `gitwildmatch` pattern style.

### New file: `modules/services/shadow-mount-excludes.nix`

```nix
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
        spec = pathspec.PathSpec.from_lines("gitwildmatch", f)

    for entry in sorted(os.listdir(project_root)):
        if spec.match_file(entry):
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
        NEW_EXCLUDES=$(${resolveExcludes} "$IGNORE_FILE" "$PROJECT" 2>/dev/null || true)

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
```

### Changes to existing files

**`modules/default.nix`** — Add the `mount.exclude.enable` and `mount.exclude.ignoreFile` options to the project source options.

**`modules/services/default.nix`** — Import the new `shadow-mount-excludes.nix` service module.

**`modules/services/host-project-mount.nix`** — No changes needed. The shadow service runs after it.

**`config.nix`** — Add defaults: `mount.exclude.enable = true;` and `mount.exclude.ignoreFile = ".agentboxignore";`

### Service ordering

```
local-fs.target
  → systemd-modules-load.service
    → mount-host-project.service  (existing, mounts 9p)
      → shadow-mount-excludes.service  (new, reads ignore file, bind-mounts)
        → multi-user.target

shadow-mount-excludes-watcher.path  (watches ignore file)
  → shadow-mount-excludes-watcher.service  (restarts shadow service on change)
```

The shadow service explicitly `requires` and runs `after` the mount service, ensuring the 9p mount is in place before the ignore file can be read and bind-mounts applied.

Any services that depend on project content (e.g., direnv activation, dev tool setup) should declare `after = [ "shadow-mount-excludes.service" ]` to avoid seeing un-shadowed host paths during the window between mount and shadow.

## Debugging

To inspect active shadow mounts:
```bash
findmnt --submounts /home/dev/project -n -o TARGET,SOURCE,FSTYPE
```

To view shadow service logs:
```bash
journalctl -u shadow-mount-excludes.service --no-pager
```

To manually trigger a reload after editing `.agentboxignore`:
```bash
systemctl restart shadow-mount-excludes.service
```

## Testing

### New test file: `tests/project-mount-excludes.nix`

Tests should use the NixOS VM testing framework (`pkgs.nixosTest`) following the patterns in existing mount tests.

#### Test Cases

**ME1: Exclude directory via .agentboxignore**
- Mock project contains `.agentboxignore` with entry `.direnv`
- Host mock project contains `.direnv/flake-profile` with content
- Guest should see `.direnv/` as empty (shadow mount hides host content)
- Guest should still see all other project files normally

**ME2: Exclude multiple paths**
- `.agentboxignore` contains `.direnv`, `result`, `node_modules`
- Host mock project contains all three with content
- Guest should see all three as empty/shadowed
- Other project files should be accessible and writable

**ME3: Exclude a file**
- `.agentboxignore` contains `result` (which is a file/symlink on host)
- Host mock project has `result` as a regular file with content
- Guest should see `result` as an empty file
- Writing to `result` in the guest should write to the shadow, not the host

**ME4: Excluded path is writable by VM**
- `.agentboxignore` contains `.direnv`
- Guest writes a file to `/home/dev/project/.direnv/test-file`
- File should exist in the shadow directory (`~/.local/shadow/.direnv/test-file`)
- File should NOT appear on the host's `.direnv` directory

**ME5: Non-excluded paths are unaffected**
- `.agentboxignore` contains `.direnv`
- Verify that other directories (`src/`, etc.) are still live read-write via 9p
- Write a file in a non-excluded directory, verify it appears on "host" side

**ME6: No ignore file (backward compat)**
- No `.agentboxignore` in project
- Default `ignoreFile` option
- Service should be a no-op
- Mount behavior is identical to current (all paths visible)

**ME7: Custom ignore file name**
- Config: `source.mount.exclude.ignoreFile = ".myignore";`
- Mock project contains `.myignore` with entries
- Should read from `.myignore` instead of `.agentboxignore`

**ME8: Comments and blank lines in ignore file**
- `.agentboxignore` contains comments (`# comment`), blank lines, and valid entries
- Only valid entries should be excluded
- Comments and blank lines should be silently skipped

**ME9: Path does not exist on host**
- `.agentboxignore` contains `nonexistent`
- Host mock project does not contain `nonexistent/`
- Service should still succeed (creates as directory on both shadow and project)
- The directory should be writable by the VM user

**ME10: Service restart re-applies mounts correctly**
- Apply shadow mounts via service start
- Run `systemctl restart shadow-mount-excludes`
- Verify mounts are still in place (no stacking, no failures)
- Verify shadowed paths are still functional

**ME11: Path with spaces or special characters in ignore file**
- `.agentboxignore` contains `my dir` and `file (1).txt`
- Host mock project contains both paths with content
- Both should be correctly shadowed

**ME12: Ignore file with Windows line endings**
- `.agentboxignore` uses `\r\n` line endings
- Patterns should still be parsed correctly (pathspec handles this)

**ME13: Path traversal attempt is warned and skipped**
- `.agentboxignore` contains `../etc/passwd`
- Service should log a warning and skip the entry
- No bind-mount should be created outside the project directory

**ME14: Nested paths are deduplicated**
- `.agentboxignore` contains `node_modules` and `node_modules/sharp`
- Only `node_modules` should be shadowed
- `node_modules/sharp` should be logged as skipped (parent already excluded)

**ME15: Gitignore glob patterns work**
- `.agentboxignore` contains a glob pattern like `.dir*`
- Host mock project contains `.direnv` and `.dirother`
- Both should be matched and shadowed

**ME16: Ignore file change triggers automatic reload**
- Start with `.agentboxignore` containing `.direnv`
- Modify `.agentboxignore` to also include `node_modules`
- Verify the watcher triggers a reload
- Verify `node_modules` is now shadowed

**ME17: Feature disabled via enable = false**
- Config: `source.mount.exclude.enable = false;`
- `.agentboxignore` exists with entries
- Shadow service should not be active
- All paths should remain visible (no shadowing)

### Registration

Add `project-mount-excludes` to `tests/default.nix` alongside existing test suites.

## Verification

1. `nix flake check` passes (includes new tests)
2. `nix build .#checks.x86_64-linux.project-mount-excludes --print-build-logs` runs all ME* tests
3. Existing mount tests (`project-mount`) continue to pass unchanged
4. A project with `.agentboxignore` listing `.direnv` boots successfully with the directory shadowed
5. A project without `.agentboxignore` boots with no behavior change
6. `source.mount.exclude.ignoreFile = ".gitignore"` reads from `.gitignore` instead
7. Editing `.agentboxignore` inside the VM triggers automatic reload without restart
8. `source.mount.exclude.enable = false` disables the feature entirely
