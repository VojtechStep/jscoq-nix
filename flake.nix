{
  description = "jsCoq";

  inputs = {
    nixpkgs.url = "nixpkgs/release-21.11";
    flake-utils.url = "github:numtide/flake-utils";
    opam-nix = {
      url = "github:tweag/opam-nix";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    npmlock2nix = {
      flake = false;
      url = "github:nix-community/npmlock2nix";
    };
  };

  # Builds the derivation in three steps:
  # 1) fetches the jsCoq sources, and puts the Coq sources where they need to be
  # 2) fetches node_modules for jsCoq's package.json, one with devDependencies and one without
  # 3) builds an OPAM scope so that package versions used between Coq, jsCoq, and serapi
  #    are consistent
  # 4) patches dune recipes to use the pre-fetched node_modules
  # 5) runs a dune build
  outputs = { self, nixpkgs, flake-utils, npmlock2nix, opam-nix }:
    let
      npmlock2nix' = npmlock2nix;
      opam-nix' = opam-nix;
    in
    with flake-utils.lib; eachSystem [
      # system.x86_64-linux
      system.i686-linux
    ]
      (
        system:
        let
          pkgs = nixpkgs.legacyPackages."${system}";
          # ocamlPackages = pkgs32.ocaml-ng.ocamlPackages_4_12;
          npmlock2nix = import npmlock2nix' {
            inherit pkgs;
          };
          opam-nix = opam-nix'.lib."${system}";
          jscoqRev = "20b51aa7e7172e1a6c5e2c2834a5e40ea7250e77";
          jscoqVersion = "0.14";
          # Fetch npm package description separately, to prevent a circular dependency
          pckJson = pkgs.fetchurl
            {
              url = "https://raw.githubusercontent.com/jscoq/jscoq/${jscoqRev}/package.json";
              sha256 = "sha256-pLrGnu/+mr+VBRJ7sFEfRSZ3tyVt6uh+VrY32y1Wp4Q=";
            };
          pckJsonLock = pkgs.fetchurl {
            url = "https://raw.githubusercontent.com/jscoq/jscoq/${jscoqRev}/package-lock.json";
            sha256 = "sha256-LJU1/r+ioApuhFsgKHuCoz7zPXrOhWivIb4QvFrZ064=";
          };
          dev-src = pkgs.stdenvNoCC.mkDerivation {
            pname = "jscoq-node_modules-base-dev";
            version = jscoqVersion;
            phases = [ "installPhase" ];
            installPhase = ''
              mkdir -p $out
              cp ${pckJson} $out/package.json
              cp ${pckJsonLock} $out/package-lock.json
            '';
          };
          prod-src = pkgs.stdenvNoCC.mkDerivation {
            pname = "jscoq-node_modules-base-dev";
            version = jscoqVersion;
            phases = [ "installPhase" ];
            installPhase = ''
              mkdir -p $out
              ${pkgs.jq}/bin/jq 'del(.devDependencies)' < ${pckJson} > $out/package.json
              cp ${pckJsonLock} $out/package-lock.json
            '';
          };
          node_modules = npmlock2nix.node_modules {
            src = dev-src;
          };
          node_modules-production = npmlock2nix.node_modules {
            src = prod-src;
          };
          coqSource = pkgs.fetchFromGitHub {
            name = "coq-source";
            owner = "coq";
            repo = "coq";
            rev = "V8.14.1";
            sha256 = "sha256-IvEs1YuabQmavYkvARoRx876y0Y+8e7KF9P6G9ZtxB0=";

            extraPostFetch =
              let
                inherit (nixpkgs) lib;
                # Fetch the patches separately, to avoid a circular dependency between jsCoqSource and coqSource
                patches = lib.pipe [
                  { name = "trampoline"; sha256 = "sha256-ij+icsVejkBi7m+oiVkrGzq7Vd64/ltVxc4VRzBc7tU="; }
                  { name = "fold"; sha256 = "sha256-hX5WoknoZvVZzqMqAXa86aLIWwMm80zcR9FM8AvClks="; }
                  { name = "timeout"; sha256 = "sha256-eQWEZLdOaF+7I5qRHV79LQbL52KuGngehZfc2b8gokw="; }
                ] [
                  (map (p: pkgs.fetchpatch ({
                    url = "https://raw.githubusercontent.com/jscoq/jscoq/${jscoqRev}/etc/patches/${p.name}.patch";
                  } // p)))
                  (map toString)
                  (builtins.concatStringsSep " ")
                ];
              in
              ''
                for p in ${patches}; do patch -d $out -p1 < $p; done
              '';
          };
          addonsPath = "_vendor+v8.14+32bit";
          coqLocalPath = addonsPath + "/coq";
          jscoqSource = pkgs.fetchFromGitHub {
            name = "jscoq-source";
            owner = "jscoq";
            repo = "jscoq";
            # The last few fixes happened after a tag
            rev = jscoqRev;
            fetchSubmodules = true;
            sha256 = "sha256-tLmDbZyPgszR9gtbt5CqomaYPSPT6TnH5M36dKw7Vuw=";

            postFetch = ''
              pushd $out
              mkdir -p ${addonsPath}
              cp -rT ${coqSource} ${coqLocalPath}
              chmod +w -R ${coqLocalPath}
              popd
            '';
          };
          opamScope = opam-nix.applyOverlays [
            (self: super:
              let
                move-sitelib = p: p.overrideAttrs (prev: {
                  preFixupPhases =
                    let
                      prevPF = prev.preFixupPhases or [ ];
                    in
                    # fixupStubs needs to happen before nixSupportPhase
                    nixpkgs.lib.optional (!builtins.elem "fixupStubs" prevPF) "fixupStubs"
                    ++ prevPF;
                  fixupStubs = ''
                    mkdir -p $OCAMLFIND_DESTDIR/stublibs
                    mv $OCAMLFIND_DESTDIR/$OPAM_PACKAGE_NAME/dll*.so $OCAMLFIND_DESTDIR/stublibs/
                  '';
                });
              in
              {
                # Fix num putting its dll in site-lib/num
                num = move-sitelib super.num;
                zarith = move-sitelib super.zarith;
              })
          ]
            (opam-nix.buildOpamProject' { inherit pkgs; }
              jscoqSource
              { });

          jscoq = opamScope.jscoq.overrideAttrs (jsc: {
            version = jscoqVersion;

            NODE_MODULES = "${node_modules}/node_modules";
            COQBUILDDIR_REL = coqLocalPath;

            patches = (jsc.patches or [ ]) ++ [ ./dune.patch ];

            postPatch = ''
              sed -i -e '/(opam/c\ (default' dune-workspace
            '';

            # prefix is where Coq will be built, libdir is where the stdlib will end up
            # ... I think?
            # needs to run at the end of configurePhase, because that's where we get OCAMLFIND_DESTDIR
            postConfigure = ''
              cur_src=$PWD
              pushd ${coqLocalPath}

              # Configure Coq
              dune exec tools/configure/configure.exe -- \
                -prefix $out \
                -libdir $OCAMLFIND_DESTDIR/coq \
                -native-compiler no -bytecode-compiler no -coqide no
              popd
            '';

            nativeBuildInputs = (jsc.nativeBuildInputs or [ ]) ++ [ node_modules.nodejs ];
            propagatedBuildInputs = (jsc.propagatedBuildInputs or [ ]) ++ [ node_modules.nodejs ];
            buildPhase = ''
              runHook preBuild
              dune build @jscoq
              patchShebangs _build/default/dist/cli.js
              dune build -p coq,coq-core,coq-stdlib
              runHook postBuild
            '';

            postFixup = ''
            '';

            installPhase = ''
              mkdir -p $out/jscoq
              runHook preInstall
              dune install --prefix $out --libdir $OCAMLFIND_DESTDIR coq coq-core coq-stdlib
              cp -R README.md index.html package.json package-lock.json \
                _build/default/{coq-pkgs,ui-js,ui-css,ui-images,ui-external,examples,dist} $out/jscoq
              mkdir -p $out/jscoq/coq-js
              cp _build/default/coq-js/jscoq_worker.bc.js $out/jscoq/coq-js
              ln -sfT $out/jscoq/dist/cli.js $out/bin/jscoq
              ln -sfT ${node_modules-production}/node_modules $out/jscoq/node_modules
              runHook postInstall
            '';
          });
        in
        {
          packages = {
            inherit jscoq dev-src prod-src;
          };
        }
      );
}
