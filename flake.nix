{
  description = "Nix infrastructure for using jsCoq with Coq to precompile your addons and integrate them into your webpage";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-21.11";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    opam-nix = {
      url = "github:tweag/opam-nix";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-compat.follows = "flake-compat";
      # FIXME: throws "cannot find flake 'flake:opam2json'", not sure why
      # inputs.opam2json.inputs.nixpkgs.follows = "nixpkgs";
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
  outputs = { self, nixpkgs, flake-utils, npmlock2nix, opam-nix, ... }:
    let
      inherit (flake-utils.lib) eachSystem;
      systems = flake-utils.lib.system;
      npmlock2nix' = npmlock2nix;
      opam-nix' = opam-nix;

      system-32bit = system:
        let
          expanded = nixpkgs.lib.systems.elaborate system;
        in
        if expanded.isLinux then systems.i686-linux
        else if expanded.isDarwin then systems.i686-darwin
        else throw "Cannot 32bit-ify system: ${system}";
    in
    eachSystem [
      systems.x86_64-linux
      systems.i686-linux
      systems.x86_64-darwin
      systems.i686-darwin
      systems.aarch64-darwin
    ]
      (
        system:
        let
          # Although the binary can be run on 64bit systems,
          # Coq and OCaml dependencies need to be built for 32bit,
          # since the JavaScript environment does not have 64bit integers
          system32 = system-32bit system;
          pkgs = nixpkgs.legacyPackages."${system}";

          # Fix for darwin - the package set i686-darwin does not
          # exist under legacyPackages
          pkgs32 = import nixpkgs {
            system = system32;
          };

          # Node things can be native
          npmlock2nix = import npmlock2nix' {
            inherit pkgs;
          };

          # The bootstrap packages can still be native
          # the 32bit-ness is introduced when building the project
          opam-nix = opam-nix'.lib."${system}";
          variant =
            let
              full = nixpkgs.lib.systems.elaborate { inherit system; };
            in
            if full.is64bit then "64bit"
            else if full.is32bit then "32bit"
            else throw "Unknown system bitness";

          # Version specifications
          jscoqRev = "20b51aa7e7172e1a6c5e2c2834a5e40ea7250e77";
          jscoqVersion = "0.14";
          coqVersionFull = "8.14.1";
          coqVersion = nixpkgs.lib.versions.majorMinor coqVersionFull;

          # Fetch npm package description separately, to prevent a circular dependency
          # Fetching and file manipulation can be native
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
            pname = "jscoq-node_modules-base-prod";
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
            rev = "V${coqVersionFull}";
            sha256 = "sha256-kXpBs2jRG4wp57vrrVhjYfGO2iekcHqaqZmS+paKuHU=";
          };
          addonsPath = "_vendor+v${coqVersion}+32bit";
          coqLocalPath = addonsPath + "/coq";
          jscoqSource = pkgs.fetchFromGitHub {
            name = "jscoq-source";
            owner = "jscoq";
            repo = "jscoq";
            # The last few fixes happened after a tag
            rev = jscoqRev;
            fetchSubmodules = true;
            sha256 = "sha256-kZvcc7hW1Hr5WXA8LWQOJNQRmm9UfE+gJjBebOU4UIQ=";
          };

          coqPatched = pkgs.stdenvNoCC.mkDerivation {
            pname = "coq-src-patched";
            version = coqVersionFull;
            src = coqSource;

            phases = [ "unpackPhase" "patchPhase" "installPhase" ];

            # Fetch the patches separately, to avoid a circular dependency between jsCoqSource and coqSource
            patches = map (f: "${jscoqSource}/etc/patches/${f}.patch")
              ([ "trampoline" "fold" "timeout" ] ++ nixpkgs.lib.optional (variant == "64bit") "coerce-32bit");

            installPhase = ''
              mkdir $out
              cp -rt $out ./*
            '';

            # Make this a fixed-output derivation
            outputHashAlgo = "sha256";
            outputHashMode = "recursive";
            outputHash =
              if (variant == "64bit")
              then "sha256-HESF8306/6LwYRf+4cBiizgq90psuGCMmEbmHeyRd18="
              else "sha256-Yus8zbi2xd8yYAOxcjto3whj9p3Np3BxeK6WEqBTv1o=";
          };
          opamScope =
            # Build with 32bit packages
            (opam-nix.materializedDefsToScope { pkgs = pkgs32; } ./package-defs.json).overrideScope'
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
                });

          jscoq = opamScope.jscoq.overrideAttrs (jsc: {
            version = jscoqVersion;

            # Override the source, otherwise opam-nix tries to fetch
            # it from GitHub
            src = jscoqSource;

            # used for building, includes dev dependencies
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
              mkdir -p ${addonsPath}
              cp -rT ${coqPatched} ${coqLocalPath}
              chmod +w -R ${coqLocalPath}
              pushd ${coqLocalPath}

              # Configure Coq
              dune exec tools/configure/configure.exe -- \
                -prefix $out \
                -libdir $OCAMLFIND_DESTDIR/coq \
                -native-compiler no -bytecode-compiler no -coqide no
              popd
            '';

            # For running =cli.js build= on Coq sources
            nativeBuildInputs = (jsc.nativeBuildInputs or [ ]) ++ [ node_modules.nodejs ];
            # For running =jscoq= in the target environment
            propagatedBuildInputs = (jsc.propagatedBuildInputs or [ ]) ++ [ node_modules.nodejs ];

            buildPhase = ''
              runHook preBuild
              dune build @jscoq
              patchShebangs _build/default/dist/cli.js
              dune build -p coq,coq-core,coq-stdlib
              runHook postBuild
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

            # We can't use setupHook, because opam-nix writes to $out/nix-support/setup-hook directly
            preFixupPhases =
              let
                prevPF = jsc.preFixupPhases or [ ];
              in
              prevPF ++
                # addCoqSetup needs to happen after nixSupportPhase
                nixpkgs.lib.optional (!builtins.elem "addCoqSetup" prevPF) "addCoqSetup";

            # Discover other coq packages
            addCoqSetup = ''
              cat >>"$out/nix-support/setup-hook" <<EOL
              addCoqPath () {
                addToSearchPath COQPATH "\$1/lib/coq/${coqVersion}/user-contrib/"
              }

              addEnvHooks "\$targetOffset" addCoqPath
              EOL
            '';
          });

          # Evaluating this attribute takes a lot of time,
          # because it requires ocaml, opam, and others as
          # _eval_ dependencies.
          # It only gets evaluated by materializeDeps below
          # opam-nix does not have a materializeOpamRepo', so merge the logic
          # of materializeOpamRepo and buildOpamProject'
          materialized =
            let
              inherit (builtins) mapAttrs concatLists attrValues filter;
              inherit (nixpkgs.lib) pipe hasAttrByPath;
              inherit (opam-nix) listRepo joinRepos makeOpamRepoRec getPinDepends;
              # Putting (js)coqSource in quotes is important - otherwise,
              # opam-nix assumes it to have a narHash, which it
              # doesn't
              # TODO: why doesn't it have a narHash?
              srcRepos = (map makeOpamRepoRec [ "${jscoqSource}" "${coqSource}" ]);
              latestVersions = mapAttrs (_: nixpkgs.lib.last) (listRepo (joinRepos srcRepos));
              pinDeps = concatLists
                (attrValues
                  (mapAttrs
                    (name: version:
                      let
                        havePackage = filter (hasAttrByPath [ "passthru" "pkgdefs" name version ]) srcRepos;
                      in
                      concatLists (map (r: getPinDepends r.passthru.pkgdefs."${name}"."${version}") havePackage))
                    latestVersions));
            in
            opam-nix.materialize
              {
                repos = pinDeps ++ srcRepos ++ [ opam-nix.opamRepository ];
                # Include local packages
                resolveArgs = {
                  dev = true;
                };
                regenCommand = "nix run .#materialize";
              }
              (latestVersions // { ocaml = "4.12.0"; });

          materializeDeps = pkgs.writeShellScript "jscoq-materialize" ''
            cp "${materialized}" package-defs.json
          '';
        in
        {
          packages = {
            inherit jscoq;
          } // (
            let
              basic-example = ((import ./examples/basic/flake.nix).outputs {
                inherit nixpkgs flake-utils;
                self = basic-example;
                jscoq-nix = self;
              });
            in
            {
              basic-example = basic-example.defaultPackage."${system}";
            }
          );

          defaultPackage = self.packages."${system}".jscoq;

          apps.materialize = {
            type = "app";
            program = "${materializeDeps}";
          };
        }
      ) // {
      templates.basic = {
        description = "Multi-file pre-compiled project";
        path = ./examples/basic;
      };
      defaultTemplate = self.templates.basic;
    };
}
