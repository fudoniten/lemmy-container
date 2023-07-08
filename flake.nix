{
  description = "Lemmy via Docker Compose on NixOS";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.05";
    utils.url = "github:numtide/flake-utils";
    lemmyDockerCfg = {
      url =
        "https://raw.githubusercontent.com/LemmyNet/lemmy-ansible/main/templates/docker-compose.yml";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, utils, lemmyDockerCfg, ... }: {
    nixosModules.lemmyDocker = import ./lemmy-docker.nix;
  };
}
