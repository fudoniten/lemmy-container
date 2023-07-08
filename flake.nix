{
  description = "Lemmy via Docker Compose on NixOS";

  inputs = { nixpkgs.url = "nixpkgs/nixos-23.05"; };

  outputs = { self, nixpkgs, ... }: {
    nixosModules = rec {
      default = lemmyDocker;
      lemmyDocker = import ./lemmy-docker.nix;
    };
  };
}
