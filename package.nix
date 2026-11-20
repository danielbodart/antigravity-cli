{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  versionCheckHook,
}:

let
  # Written by scripts/update.sh, which cross-checks every hash in it against
  # the bytes of the tarball it names before it lands.
  pinned = builtins.fromJSON (builtins.readFile ./sources.json);

  source =
    pinned.sources.${stdenv.hostPlatform.system}
      or (throw "antigravity-cli: no release is published for ${stdenv.hostPlatform.system}");
in

stdenv.mkDerivation {
  pname = "antigravity-cli";
  inherit (pinned) version;

  # The tarball holds a single file, a Go binary called `antigravity`, so
  # there is nothing to unpack into a directory.
  src = fetchurl {
    inherit (source) url hash;
  };
  sourceRoot = ".";

  nativeBuildInputs = [ autoPatchelfHook ];

  # A 270 MB Go binary with its own runtime. Stripping it saves nothing worth
  # having and costs the build time.
  dontStrip = true;

  # The binary links only glibc (libc, libm, libresolv and friends), which
  # autoPatchelfHook finds in the stdenv. What it needs patching for is the
  # ELF interpreter, which on NixOS is not at /lib64.
  installPhase = ''
    runHook preInstall
    install -Dm755 antigravity $out/bin/agy
    runHook postInstall
  '';

  # `agy --version` prints the release number and nothing else, and needs no
  # network and no login, so it runs in the build sandbox. It exercises the
  # patched interpreter and the whole dynamic link. versionCheckHook gives it
  # a throwaway HOME.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  # The manifest's own version is the short one (1.5.13), which is what the
  # binary reports. The build suffix in the tarball's URL is only in
  # sources.json.
  passthru.build = pinned.build;

  meta = {
    description = "Google Antigravity CLI (agy), the terminal agent from Google";
    homepage = "https://antigravity.google";
    # Proprietary. Nix refuses to evaluate this until nixpkgs.config.allowUnfree
    # (or an allowUnfreePredicate naming "antigravity-cli") permits it.
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "agy";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
