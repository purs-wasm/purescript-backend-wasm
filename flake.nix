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

        # The published `purs-wasm` CLI (npm) wrapped to run on Nix. The npm package is self-contained
        # (an esbuild bundle + the precompiled ulib lib + the runtime); its only runtime need is the
        # binaryen tools (`wasm-merge`/`wasm-as`/`wasm-dis`), which we provide from nixpkgs and inject
        # via the CLI's `main(cliRoot)(binaryenBinDir)` entry — so no npm `binaryen` dependency, and
        # native (not JS-wrapper) binaryen.
        nixEntry = pkgs.writeText "purs-wasm-nix-entry.mjs" ''
          import { main } from "./bundle/index.js";
          import { dirname } from "node:path";
          import { fileURLToPath } from "node:url";
          const cliRoot = dirname(fileURLToPath(import.meta.url));
          main(cliRoot)("${pkgs.binaryen}/bin")();
        '';
        purs-wasm = pkgs.stdenv.mkDerivation rec {
          pname = "purs-wasm";
          version = "0.1.0";
          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/purs-wasm/-/purs-wasm-${version}.tgz";
            hash = "sha256-nbj4QNwVcoG601vclWiwoWjMtHqyizh0364d/4nosZQ=";
          };
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/libexec/purs-wasm
            cp -R . $out/libexec/purs-wasm/
            cp ${nixEntry} $out/libexec/purs-wasm/nix-entry.mjs
            makeWrapper ${pkgs.nodejs_24}/bin/node $out/bin/purs-wasm \
              --add-flags "$out/libexec/purs-wasm/nix-entry.mjs"
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "An experimental WebAssembly (GC) backend for the PureScript compiler";
            homepage = "https://purs-wasm.github.io/documentation/";
            license = licenses.mit;
            mainProgram = "purs-wasm";
          };
        };
        purs-wasm-app = {
          type = "app";
          program = "${purs-wasm}/bin/purs-wasm";
        };
      in
        {
          packages = {
            purs-wasm = purs-wasm;
            default = purs-wasm;
          };
          apps = {
            purs-wasm = purs-wasm-app;
            default = purs-wasm-app;
          };
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
