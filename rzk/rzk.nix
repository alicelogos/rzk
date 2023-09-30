{ mkDerivation, alex, array, base, bifunctors, bytestring, doctest
, Glob, happy, hpack, lib, mtl, optparse-generic, QuickCheck
, template-haskell, text
}:
mkDerivation {
  pname = "rzk";
  version = "0.6.4";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    array base bifunctors bytestring Glob mtl optparse-generic
    template-haskell text
  ];
  libraryToolDepends = [ alex happy hpack ];
  executableHaskellDepends = [
    array base bifunctors bytestring Glob mtl optparse-generic
    template-haskell text
  ];
  executableToolDepends = [ alex happy ];
  testHaskellDepends = [
    array base bifunctors bytestring doctest Glob mtl optparse-generic
    QuickCheck template-haskell text
  ];
  testToolDepends = [ alex happy ];
  prePatch = "hpack";
  homepage = "https://github.com/rzk-lang/rzk#readme";
  description = "An experimental proof assistant for synthetic ∞-categories";
  license = lib.licenses.bsd3;
}
