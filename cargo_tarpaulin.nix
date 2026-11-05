# A script which runs the test suite with code coverage (cargo-tarpaulin, Linux/x86_64
# only upstream) and writes an HTML report to target/coverage/tarpaulin-report.html.
# Further arguments are passed on to `cargo tarpaulin`, e.g. `-p imbuf` or `--out Lcov`.
#
#   apps.coverage = {
#     type = "app";
#     program = toString (import ./cargo_tarpaulin.nix {
#       inherit pkgs;
#       rust = fenix.packages.${system}.stable.toolchain;
#       # Whatever the tests need to build, and variables like RUSTFLAGS or LIBCLANG_PATH
#       path = [ pkgs.stdenv.cc pkgs.pkg-config ];
#       env = { };
#     });
#   };
{
  pkgs,
  # Anything with bin/cargo and bin/rustc
  rust,
  # Additional programs on the PATH, e.g. a C compiler for build scripts
  path ? [ ],
  # Environment variables for the build and the tests
  env ? { },
  # Arguments before the ones of the caller
  args ? [
    "--out" "Html"
    "--output-dir" "target/coverage"
    # Per test, the default is 60
    "--timeout" "120"
    # Integration tests would count as covered code. Relative patterns like `tests/*`
    # don't match the ones of the member crates
    "--exclude-files" "*/tests/*"
    "--all-features"
  ],
}:
pkgs.writeShellScript "coverage" ''
  set -euo pipefail
  export PATH="${pkgs.lib.makeBinPath ([ rust pkgs.cargo-tarpaulin ] ++ path)}:$PATH"
  ${pkgs.lib.concatStringsSep "\n" (
    pkgs.lib.mapAttrsToList (name: value: "export ${name}=${pkgs.lib.escapeShellArg value}") env
  )}
  cargo --version
  cargo tarpaulin ${pkgs.lib.escapeShellArgs args} "$@"
  echo
  echo "Open target/coverage/tarpaulin-report.html in a browser to view the report."
''
