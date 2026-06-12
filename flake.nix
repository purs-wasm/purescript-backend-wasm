{
  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url  = "github:numtide/flake-utils";
    purescript-overlay = {
      url = "github:thomashoneyman/purescript-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-claude-code.url = "github:ryoppippi/nix-claude-code";
 };

  outputs = { self, nixpkgs, flake-utils, purescript-overlay, nix-claude-code }: 
    flake-utils.lib.eachDefaultSystem (system:
      let 
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            purescript-overlay.overlays.default
          ];
        }; 
        claude-code = nix-claude-code.packages.${system}.default;
      in 
        {
          devShells.default = pkgs.mkShellNoCC {
            buildInputs = with pkgs; [
              purs 
              spago
              purs-tidy-bin.purs-tidy-0_10_0
              purs-backend-es
              esbuild
              nodejs_24
              pnpm
              gnuplot
              claude-code
            ];
          };
        }
    );
}