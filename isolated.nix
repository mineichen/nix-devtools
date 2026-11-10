# An isolated development shell (e.g. for AI agents) built with bubblewrap.
#
# - The sandbox only contains the closure of the given packages (read-only). Nothing
#   else of the host's /nix/store, /usr, /etc, $HOME, ... is visible.
# - No environment variables of the host are passed, only `env`, `passEnv`, `envFiles`
#   and TERM.
# - Own PID, IPC, UTS, cgroup and user namespace: host processes aren't visible.
#   Nested user namespaces are disabled, as they expose a lot of kernel attack surface.
# - The network is shared with the host. This includes services on localhost and
#   abstract unix sockets, e.g. X11's, if it trusts local users (`xhost` lists SI:localuser).
# - The only writable host directory is the workspace. Everything else (HOME, /tmp,
#   /nix/store) is a tmpfs, which is gone when the shell exits.
# - Nix works inside (unless `nix = null`). Whatever it builds or fetches only exists
#   in that sandbox.
# - Optionally Claude Code, logged in with a long-lived token of your subscription:
#   create it once on the host with `<launcher> --claude-login` (with nix run:
#   `nix run .#isolated -- --claude-login`). Everything in the sandbox can read it.
#
# Requires Linux with unprivileged user namespaces. On Ubuntu (23.10 and later) they
# have to be allowed for nix's bwrap with an AppArmor profile; the launcher prints how.
#
# Usage in a flake:
#
#   apps.isolated = {
#     type = "app";
#     program = pkgs.lib.getExe (import ./isolated.nix {
#       inherit pkgs inputs;
#       name = "myproject-isolated";
#       packages = [ pkgs.coreutils pkgs.git pkgs.cargo pkgs.claude-code ];
#     });
#   };
#
# and then `nix run .#isolated [dir]`. The workspace dir (default: the current one) is
# mounted at the same path as on the host, so build caches (e.g. cargo's target) and
# paths in messages match. If it's a parent of the current directory (e.g. ..), the
# shell still starts in the current one.
{
  pkgs,
  # Name of the launcher executable and the sandbox's hostname
  name ? "isolated",
  # The only programs on the PATH, besides bash (the shell) and nix
  packages ? [ ],
  # Environment variables in the sandbox
  env ? { },
  # Names of host environment variables passed into the sandbox (if set), e.g. a
  # token like [ "GITHUB_TOKEN" ]. Everything in the sandbox can read them.
  passEnv ? [ ],
  # Environment variables read from host files (if they exist) when the sandbox starts,
  # with paths relative to $HOME, e.g. { GITHUB_TOKEN = ".config/gh-token"; }.
  # Host variables of `passEnv` take precedence.
  envFiles ? { },
  # Claude Code in the sandbox, null to leave it out. An attrset with (all optional):
  # - package: pkgs.claude-code by default (unfree, so it has to be allowed in pkgs)
  # - pluginDirs: passed as --plugin-dir, e.g. a directory with .claude-plugin/plugin.json
  # - tokenFile: where --claude-login stores the token, relative to $HOME. The host
  #   variable CLAUDE_CODE_OAUTH_TOKEN takes precedence.
  claude ? null,
  # Store paths available in the sandbox without being on its PATH, e.g. the
  # program of another app, so `nix run .#app` doesn't have to build anything.
  extraStorePaths ? [ ],
  # The flake's inputs. Their sources are available in the sandbox, so the flake
  # evaluates without fetching. If there is a nixpkgs input, it's pinned as `nixpkgs`
  # in the registry and NIX_PATH.
  inputs ? { },
  # Shell commands run in the sandbox before the interactive shell starts
  shellHook ? "",
  # More writable host directories, relative to the workspace (e.g. [ "../other-repo" ]),
  # mounted at their host path. Missing ones are skipped.
  extraMounts ? [ ],
  # Additional arguments for bwrap, e.g. [ "--ro-bind" "/etc/gitconfig" "/etc/gitconfig" ]
  bwrapArgs ? [ ],
  # Nix inside the sandbox, null to leave it out
  nix ? pkgs.nix,
}:
let
  lib = pkgs.lib;
  withNix = nix != null;
  withClaude = claude != null;
  home = "/home/user";

  claudeCfg = {
    package = pkgs.claude-code;
    pluginDirs = [ ];
    tokenFile = ".config/claude-isolated-token";
  } // (if withClaude then claude else { });
  claudeWrapper =
    if claudeCfg.pluginDirs == [ ] then claudeCfg.package
    else pkgs.writeShellScriptBin "claude" ''
      exec ${claudeCfg.package}/bin/claude ${lib.escapeShellArgs
        (lib.concatMap (dir: [ "--plugin-dir" (toString dir) ]) claudeCfg.pluginDirs)} "$@"
    '';
  claudeSetup = ''
    # Skips Claude's onboarding and trust dialog, as HOME is new in every session
    printf '{"hasCompletedOnboarding":true,"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$PWD" \
      > ~/.claude.json
    if [ -z "''${CLAUDE_CODE_OAUTH_TOKEN-}" ]; then
      echo "No Claude token. Create one on the host with: ${name} --claude-login"
      echo "(with nix run: nix run .#<app> -- --claude-login)"
    fi
  '';

  allEnvFiles = lib.optionalAttrs withClaude {
    CLAUDE_CODE_OAUTH_TOKEN = claudeCfg.tokenFile;
  } // envFiles;
  allPassEnv = passEnv ++ lib.optional withClaude "CLAUDE_CODE_OAUTH_TOKEN";

  profile = pkgs.buildEnv {
    name = "${name}-env";
    paths = packages
      ++ lib.optional withClaude claudeWrapper
      ++ [ (lib.lowPrio pkgs.bashInteractive) ]
      ++ lib.optional withNix (lib.lowPrio nix);
  };

  nixEtc = pkgs.linkFarm "${name}-nix-etc" ({
    "nix.conf" = pkgs.writeText "nix.conf" ''
      experimental-features = nix-command flakes
      # The build sandbox needs nested user namespaces, which bwrap disables
      sandbox = false
    '';
  } // lib.optionalAttrs (inputs ? nixpkgs) {
    "registry.json" = pkgs.writeText "registry.json" (builtins.toJSON {
      version = 2;
      flakes = [{
        from = { type = "indirect"; id = "nixpkgs"; };
        to = {
          type = "path";
          path = inputs.nixpkgs.outPath;
          inherit (inputs.nixpkgs) narHash;
        };
      }];
    });
  });

  sandboxEnv = {
    PATH = lib.optionalString withNix "${home}/.nix-profile/bin:" + "${profile}/bin";
    HOME = home;
    USER = "user";
    SHELL = "/bin/bash";
    # Built into glibc, no locale archive needed
    LANG = "C.UTF-8";
    SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
  } // lib.optionalAttrs withNix {
    # Otherwise, nix would use a store in ~/.local/share/nix/root while /nix/var is missing
    NIX_REMOTE = "local";
  } // lib.optionalAttrs (withNix && inputs ? nixpkgs) {
    NIX_PATH = "nixpkgs=${inputs.nixpkgs}";
  } // env;

  entrypoint = pkgs.writeShellScript "${name}-entrypoint" ''
    ${lib.optionalString withNix ''
      # The store starts with exactly the paths of the closure
      ${nix}/bin/nix-store --load-db < /var/lib/isolated/registration
    ''}
    ${lib.optionalString withClaude claudeSetup}
    ${shellHook}
    exec ${pkgs.bashInteractive}/bin/bash
  '';

  # Sources of all flake inputs (transitively)
  inputSources =
    let
      collect = input: [ input.outPath ]
        ++ lib.concatMap collect (builtins.attrValues (input.inputs or { }));
    in
    lib.unique (lib.concatMap collect
      (builtins.attrValues (builtins.removeAttrs inputs [ "self" ])));

  # The only store paths the sandbox can see
  closure = pkgs.closureInfo {
    rootPaths = [ entrypoint profile pkgs.cacert pkgs.coreutils ]
      ++ lib.optional withNix nixEtc
      ++ extraStorePaths
      ++ inputSources;
  };

  bwrap = "${pkgs.bubblewrap}/bin/bwrap";
in
pkgs.writeShellScriptBin name ''
  set -euo pipefail
  PATH="${lib.makeBinPath [ pkgs.coreutils ]}:$PATH"

  # Paths relative to $HOME
  hostpath() {
    case "$1" in
      /*) echo "$1" ;;
      *) echo "$HOME/$1" ;;
    esac
  }

  ${lib.optionalString withClaude ''
    if [ "''${1-}" = --claude-login ]; then
      # Runs on the host (not sandboxed), so the browser can be opened
      ${claudeCfg.package}/bin/claude setup-token
      read -rsp "Paste the token: " token
      echo
      [ -n "$token" ] || exit 1
      file="$(hostpath ${lib.escapeShellArg claudeCfg.tokenFile})"
      mkdir -p "$(dirname "$file")"
      install -m 600 /dev/null "$file"
      printf '%s' "$token" > "$file"
      echo "Saved to $file"
      exit
    fi
  ''}
  if [ $# -gt 1 ] || [[ "''${1-}" == -* ]]; then
    echo "usage: ${name} [dir]${lib.optionalString withClaude " | ${name} --claude-login"}" >&2
    exit 2
  fi
  workspace="$(realpath "''${1:-.}")"
  workdir="$(realpath .)"
  case "$workdir/" in
    "$workspace"/*) ;;
    *) workdir="$workspace" ;;
  esac

  extra=()
  for rel in ${lib.escapeShellArgs extraMounts}; do
    dir="$(realpath -m "$workspace/$rel")"
    if [ -d "$dir" ]; then
      extra+=(--bind "$dir" "$dir")
    fi
  done

  if ! error="$(${bwrap} --unshare-all --share-net --ro-bind / / true 2>&1)"; then
    echo "error: bubblewrap doesn't work: $error" >&2
    if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2> /dev/null)" = 1 ]; then
      # The glob also allows anything else in the store named bin/bwrap, which every
      # user can add. Fine for a personal machine; it only weakens a kernel hardening.
      cat >&2 <<'EOF'
  AppArmor restricts unprivileged user namespaces. Allow them for nix's bwrap with:
    printf 'abi <abi/4.0>,\nprofile nix-bwrap /nix/store/*/bin/bwrap flags=(unconfined) {\n  userns,\n}\n' | sudo tee /etc/apparmor.d/nix-bwrap
    sudo apparmor_parser -r /etc/apparmor.d/nix-bwrap
  EOF
    fi
    exit 1
  fi

  # Keeps the host from garbage collecting the mounted paths while the sandbox runs.
  # Prefers the host's nix, which matches its store.
  tmp="$(mktemp -d "''${TMPDIR:-/tmp}/${name}.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  hostnixstore="$(command -v nix-store || echo ${pkgs.nix}/bin/nix-store)"
  if ! "$hostnixstore" --add-root "$tmp/gcroot" --realise ${closure} > /dev/null; then
    echo "warning: no gc root, garbage collecting the host's store can break the sandbox" >&2
  fi

  mounts=()
  while read -r path; do
    if [ -L "$path" ]; then
      mounts+=(--symlink "$(readlink "$path")" "$path")
    else
      mounts+=(--ro-bind "$path" "$path")
    fi
  done < ${closure}/store-paths

  passenv=()
  for pair in ${lib.escapeShellArgs (lib.mapAttrsToList (n: f: "${n}=${f}") allEnvFiles)}; do
    file="$(hostpath "''${pair#*=}")"
    if [ -r "$file" ]; then
      passenv+=(--setenv "''${pair%%=*}" "$(< "$file")")
    fi
  done
  for var in ${lib.escapeShellArgs allPassEnv}; do
    if [ -n "''${!var-}" ]; then
      passenv+=(--setenv "$var" "''${!var}")
    fi
  done

  # Without TIOCSTI restrictions (dev.tty.legacy_tiocsti), the sandbox could inject
  # input into this terminal, unless it runs in its own session (no job control then).
  session=()
  if [ "$(cat /proc/sys/dev/tty/legacy_tiocsti 2> /dev/null || echo 1)" != 0 ]; then
    session=(--new-session)
  fi

  ${bwrap} \
    --unshare-all --share-net --unshare-user --disable-userns \
    --die-with-parent "''${session[@]}" \
    --hostname ${lib.escapeShellArg name} \
    --dev /dev --proc /proc --tmpfs /tmp \
    --dir /nix/store \
    "''${mounts[@]}" \
    --symlink ${profile}/bin /bin \
    --symlink ${pkgs.coreutils}/bin/env /usr/bin/env \
    --dir /etc/ssl/certs \
    --symlink ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt \
    ${lib.optionalString withNix
      "--symlink ${nixEtc} /etc/nix --ro-bind ${closure}/registration /var/lib/isolated/registration"} \
    --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
    --ro-bind-try /etc/hosts /etc/hosts \
    --ro-bind-data 3 /etc/passwd 3< <(printf 'user:x:%s:%s::${home}:/bin/bash\n' "$(id -u)" "$(id -g)") \
    --ro-bind-data 4 /etc/group 4< <(printf 'user:x:%s:\n' "$(id -g)") \
    --dir ${home} \
    --bind "$workspace" "$workspace" \
    "''${extra[@]}" \
    --chdir "$workdir" \
    --clearenv \
    ${lib.concatStringsSep " " (lib.mapAttrsToList
      (n: v: "--setenv ${lib.escapeShellArg n} ${lib.escapeShellArg (toString v)}") sandboxEnv)} \
    --setenv TERM "''${TERM:-xterm}" \
    "''${passenv[@]}" \
    ${lib.escapeShellArgs bwrapArgs} \
    -- ${entrypoint}
''
