{
  description = "Website with jsCoq integration and custom pre-built packages";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-21.11";
    jscoq-nix.url = "github:VojtechStep/jscoq-nix";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, jscoq-nix, flake-utils }:
    with flake-utils.lib; eachSystem [
      system.x86_64-linux
      system.i686-linux
    ]
      (
        system:
        let
          pkgs = nixpkgs.legacyPackages."${system}";
          jscoq = jscoq-nix.packages."${system}".jscoq;
        in
        {
          defaultPackage = pkgs.stdenv.mkDerivation {
            pname = "jscoq-example";
            version = "0.1.0";

            src = builtins.path { path = ./.; name = "jscoq-example-src"; };

            JSCOQDIR = "${jscoq}/jscoq";
            nativeBuildInputs = [ jscoq ];

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r build/html/* "$out/"
              runHook postInstall
            '';
          };
        }
      );
}
