# A Claude Code plugin which only declares rust-analyzer as LSP server, like
# rust-analyzer-lsp@claude-plugins-official, but with an explicitly chosen
# rust-analyzer instead of whatever is on the PATH. Evaluates to the plugin directory,
# for `claude --plugin-dir` (e.g. `claude.pluginDirs` of isolated.nix).
#
#   import ./claude_rust_analyzer.nix {
#     inherit pkgs;
#     # Anything with bin/rust-analyzer, e.g. pkgs.rust-analyzer, a fenix toolchain or
#     # fenix.packages.${system}.rust-analyzer
#     rust-analyzer = fenix.packages.${system}.stable.rust-analyzer;
#   }
{ pkgs, rust-analyzer }:
let
  name = "rust-analyzer-lsp";
  dir = pkgs.writeTextDir "${name}/.claude-plugin/plugin.json" (builtins.toJSON {
    inherit name;
    description = "Rust language server for code intelligence and analysis";
    version = "1.0.0";
    lspServers.rust-analyzer = {
      command = "${rust-analyzer}/bin/rust-analyzer";
      extensionToLanguage.".rs" = "rust";
    };
  });
in
"${dir}/${name}"
