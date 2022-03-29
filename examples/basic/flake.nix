{
  description = "Website with jsCoq integration and custom pre-built packages";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-21.11";
    flake-utils.url = "github:numtide/flake-utils";
    jscoq-nix = {
      url = "github:VojtechStep/jscoq-nix";
      # uncomment at your own risk, may result in rebuilding jscoq
      # inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, jscoq-nix, flake-utils }:
    with flake-utils.lib; eachSystem [
      system.x86_64-linux
      system.i686-linux
      system.x86_64-darwin
      system.i686-darwin
      system.aarch64-darwin
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

          devShell =
            let
              defaultPackage = self.defaultPackage."${system}";
            in
            pkgs.mkShell {
              name = "jscoq-basic-shell";
              inherit (defaultPackage) JSCOQDIR;
              inputsFrom = [ defaultPackage ];
              nativeBuildInputs = [ pkgs.miniserve ];
            };
        }
      );
}
