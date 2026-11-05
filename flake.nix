{
  description = "Building blocks to develop with nix";

  # Every function takes `pkgs` (and more, see the header of each file)
  outputs = { ... }: {
    lib = {
      isolated = import ./isolated.nix;
      cargoTarpaulin = import ./cargo_tarpaulin.nix;
      claudeRustAnalyzer = import ./claude_rust_analyzer.nix;
    };
  };
}
