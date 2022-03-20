(import
  (
    let
      locked = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.flake-compat.locked;
    in
    fetchTarball {
      url = "https://github.com/edolstra/flake-compat/archive/${locked.rev}.tar.gz";
      sha256 = locked.narHash;
    }
  )
  { src = ./.; }
).defaultNix
