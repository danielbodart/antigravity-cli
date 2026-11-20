{
  description = "Google's Antigravity CLI (agy) for Linux, pinned to Google's release feed and cross-checked against the bytes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  # Offered, not imposed. Nix applies these only for a trusted user, and
  # otherwise says it is ignoring them. See the README for setting the
  # substituter in a NixOS configuration instead, which is what most people
  # actually want.
  nixConfig = {
    extra-substituters = [ "https://danielbodart.cachix.org" ];
    extra-trusted-public-keys = [
      "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
    ];
  };

  outputs =
    { self, nixpkgs }:
    let
      # Google publishes the CLI for Linux, macOS and Windows. This flake
      # packages the two Linux builds, amd64 and arm64.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      # The upstream binary is proprietary, so the flake enables unfree for its
      # own outputs. Consumers who take the overlay instead get their own
      # nixpkgs config, and will need allowUnfree set there.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      overlay = final: prev: {
        antigravity-cli = final.callPackage ./package.nix { };
      };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          antigravity-cli = (pkgsFor system).callPackage ./package.nix { };
        in
        {
          inherit antigravity-cli;
          default = antigravity-cli;
        }
      );

      apps = forAllSystems (system: {
        default = self.apps.${system}.antigravity-cli;
        antigravity-cli = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.antigravity-cli;
          meta.description = "Run the Antigravity CLI";
        };
      });

      # `nix flake check` builds these. The package build is the real test: it
      # runs `agy --version` as its installCheck, so a green build means the
      # patched binary starts.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (self.packages.${system}) antigravity-cli;

          # sources.json is machine-written, and everything the build trusts
          # is in it. This catches a hand edit that leaves it inconsistent
          # with itself: a URL for another version, another architecture's
          # tarball under the wrong system, or a hash that is not sha512.
          sources-are-consistent =
            pkgs.runCommand "antigravity-cli-sources-are-consistent" { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                jq -e '
                  . as $s
                  | ($s.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
                    and ($s.build | test("^[0-9]+$"))
                    and ($s.sources | keys == ["aarch64-linux", "x86_64-linux"])
                    and ($s.sources | to_entries | all(
                      .value.url | startswith("https://storage.googleapis.com/antigravity-public/antigravity-cli/\($s.version)-\($s.build)/")))
                    and ($s.sources."x86_64-linux".url | endswith("/linux-x64/cli_linux_x64.tar.gz"))
                    and ($s.sources."aarch64-linux".url | endswith("/linux-arm/cli_linux_arm64.tar.gz"))
                    and ($s.sources | to_entries | all(.value.hash | test("^sha512-[A-Za-z0-9+/]{86}==$")))
                ' ${./sources.json} >/dev/null || {
                  echo "sources.json is not self-consistent" >&2
                  exit 1
                }
                touch $out
              '';

          shellcheck =
            pkgs.runCommand "antigravity-cli-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; }
              ''
                shellcheck ${./scripts/update.sh}
                touch $out
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              coreutils
              curl
              gnutar
              gzip
              jq
              nixfmt
              shellcheck
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
