{
  inputs.haskell-language-server = {
    url = "github:haskell/haskell-language-server/ff4f29f859244f6e828ecf74fab6e8a6b745c020";
    inputs.nixpkgs.url = "github:deemp/flakes?dir=source-flake/nixpkgs";
  };
  outputs = x: { };
}
