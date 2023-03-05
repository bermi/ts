{ stdenv
, lib
, zig
, pkg-config
}:

stdenv.mkDerivation rec {
  pname = "ts";
  version = "0.1.0";

  src = ./..;

  nativeBuildInputs = [ zig pkg-config ];

  buildInputs = [];

  dontConfigure = true;

  preBuild = ''
    # Necessary for zig cache to work
    export HOME=$TMPDIR
  '';

  installPhase = ''
    runHook preInstall
    zig build -Doptimize=ReleaseFast --prefix $out install
    runHook postInstall
  '';

  outputs = [ "out" "dev" ];

  meta = with lib; {
    description = "High performance version of moreutils ts, which prefixes lines with timestamps.";
    homepage = "https://github.com/bermi/ts";
    license = licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  };
}
