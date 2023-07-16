{
  description = "Lemmy via Docker Compose on NixOS";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.05";
    arion.url = "github:hercules-ci/arion";
  };

  outputs = { self, nixpkgs, arion, ... }: {
    nixosModules = rec {
      default = lemmyDocker;
      lemmyDocker = { ... }: {
        imports = [ arion.nixosModules.arion ./lemmy-docker.nix ];
      };
    };
  };
}
