{
  inputs.poetry2nix = {
    url = "github:nix-community/poetry2nix/4f8d61cd936f853242a4ce1fd476f5488c288c26";
    inputs.nixpkgs.url = "github:deemp/flakes?dir=source-flake/nixpkgs";
  };
  outputs = x: { };
}
