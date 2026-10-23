{ buildPythonPackage
, clightning
, hatchling
, pytestCheckHook
, bitstring
, cryptography
, coincurve
, base58
, pysocks
}:

buildPythonPackage rec {
  pname = "pyln-proto";
  version = clightning.version;
  format = "pyproject";

  inherit (clightning) src;

  # Upstream depends on the `coincurve-cp314-fix` fork only for its Python 3.14
  # wheels. nixpkgs builds `coincurve` from source and doesn't need the fork.
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail 'coincurve-cp314-fix' 'coincurve'
  '';

  # Upstream requires coincurve >= 22.0.1, nixpkgs has 21.0.0
  pythonRelaxDeps = [ "coincurve" ];

  nativeBuildInputs = [ hatchling ];

  propagatedBuildInputs = [
    bitstring
    cryptography
    coincurve
    base58
    pysocks
  ];

  checkInputs = [ pytestCheckHook ];

  pythonNamespaces = [ "pyln" ];

  postUnpack = "sourceRoot=$sourceRoot/contrib/pyln-proto";
}
