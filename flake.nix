{
  description = "restic-backup-runner";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        packages = with pkgs; [
          restic
          bash
          coreutils
          jq
          postgresql
          sqlite
          xh
        ];
      in
      {
        packages.default = pkgs.writeShellApplication {
          name = "restic-backup-runner";
          runtimeInputs = packages;
          text = builtins.readFile ./backup_script.sh;
        };

        devShells.default = pkgs.mkShell {
          packages = packages;
          shellHook = ''
            echo "🔄 Restic backup runner development environment ready!"
          '';
        };
      }
    )
    // {
      overlays.default = final: prev: {
        restic-backup-runner = self.packages.${final.system}.default;
      };

      nixosModules.default = import ./restic-backup-runner.nix;
    };
}
