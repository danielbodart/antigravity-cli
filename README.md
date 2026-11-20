# antigravity-cli

A Nix flake for Google's **Antigravity CLI**, the `agy` terminal agent, on
Linux.

Google ships the CLI as a plain tarball holding one Go binary, for amd64 and
arm64, and publishes each release in a small JSON feed. This flake repackages
that binary for NixOS and Nix on other distributions, and keeps the pin current
automatically. It packages the CLI only: not the Antigravity IDE, the Hub or
the SDK.

```nix
{
  inputs.antigravity-cli.url = "github:danielbodart/antigravity-cli";
}
```

## Install

### NixOS

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    antigravity-cli.url = "github:danielbodart/antigravity-cli";
  };

  outputs = { nixpkgs, antigravity-cli, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ antigravity-cli.overlays.default ];
          nixpkgs.config.allowUnfree = true;
          environment.systemPackages = [ pkgs.antigravity-cli ];
        })
      ];
    };
  };
}
```

or without the overlay:

```nix
environment.systemPackages = [ inputs.antigravity-cli.packages.${pkgs.system}.default ];
```

### Home Manager, or any other profile

```nix
home.packages = [ inputs.antigravity-cli.packages.${pkgs.system}.default ];
```

### Try it without installing

```bash
nix run github:danielbodart/antigravity-cli
```

The binary is installed as `agy`.

### Unfree

Antigravity is proprietary, so the package is marked unfree and Nix refuses to
evaluate it until you allow that. This flake's own outputs
(`packages.<system>.default`, `nix run`) set `allowUnfree` for themselves, so
they just work. If you take the **overlay** instead, the package is built with
*your* nixpkgs configuration, and you need either

```nix
nixpkgs.config.allowUnfree = true;
```

or a narrower

```nix
nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "antigravity-cli" ];
```

## Platforms

`x86_64-linux` and `aarch64-linux`. Google also ships macOS and Windows
builds; they are not packaged here.

## Provenance

Read this one carefully, because it is weaker than it looks like it should be.

Google gives no signature for the CLI. There is no PGP key, no detached
signature and no signed index. What it publishes is:

- a JSON feed per platform, `{version, url, sha512}`, from a Cloud Run service;
- the tarball that `url` names, in a `storage.googleapis.com` bucket.

So the trust chain is **TLS to Google's feed, then the feed's hash, then TLS to
Google's bucket.** The hash and the binary come from the same publisher over
the same kind of channel, which means the hash cannot protect you from a
compromise of Google's publishing itself. That is a weaker chain than
[claude-desktop](https://github.com/danielbodart/claude-desktop)'s, which runs
from a pinned PGP key down to the hash. There is nothing here to pin a key to.

What `scripts/update.sh` does with that is a cross-check rather than a
signature:

| Check | What it catches |
| --- | --- |
| The URL is under `https://storage.googleapis.com/antigravity-public/antigravity-cli/` | A feed pointed at another host, or at a path with `..` in it |
| The version in the URL is the version in the feed | A feed that names one release and links another |
| Both architectures agree on the version and the build | A release that is only half published |
| Each tarball is downloaded and hashed, and must equal the feed's sha512 | A feed and a bucket that disagree, a truncated or tampered download |
| The tarball holds exactly one file, `antigravity` | A different archive under the same name |

Only then is the hash written to `sources.json`, as an SRI hash that Nix
checks again at build time. Nothing in `sources.json` is taken on trust from
the feed alone.

CI re-derives `sources.json` on every pull request, downloading both tarballs
again, and fails if a hand-edited file disagrees with the feed at the same
release.

## Pinning

Every release is tagged `v<version>`, so
`github:danielbodart/antigravity-cli/v1.5.13` pins one exactly.

Google's version is `major.minor.patch`; the long number after it in the
tarball's URL (`1.5.13-5999302598852608`) is a build id, kept in
`sources.json` as `build`. The tag is the short version. If Google ever
republishes a version under a new build, that tag is already taken, and the new
one is `v<version>-<build>` instead of moving a tag someone may have pinned.

Nothing about updating this repository changes what you get when you pin a
tag. `nix flake update` is still the only thing that moves your version.

## Update cadence

- **Hourly** (`upstream.yml`, minute 17): reads the feed. When the release has
  changed, it regenerates `sources.json`, builds the package and runs
  `agy --version` on both `x86_64-linux` and `aarch64-linux` runners, and only
  if both succeed commits to `trunk`, tags `v<version>` and creates a GitHub
  release. This pushes to `trunk` rather than opening a pull request on
  purpose: a pull request raised with the default token does not trigger
  workflows, so an auto-merged one would land without ever having been built.
- **Weekly**, Sunday 21:23 UTC (`update.yml`): moves `flake.lock`, built and run
  the same way before it lands. Not a release, so it gets no tag.
- If the hourly job fails, it opens an issue labelled `auto-failure` and
  comments on it while the failure continues. The first green run closes it.

## Binary cache

CI pushes both architectures to `https://danielbodart.cachix.org`, so you can
substitute the build instead of downloading a 100 MB tarball and patching it
yourself.

The flake offers the cache through `nixConfig`, which Nix applies only if you
are a trusted user and otherwise reports as ignored. On NixOS the reliable
place to put it is your own configuration:

```nix
nix.settings = {
  substituters = [ "https://danielbodart.cachix.org" ];
  trusted-public-keys = [
    "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
  ];
};
```

Building it yourself is cheap in any case: there is no compile, only a fetch
and an `autoPatchelfHook` pass over one file.

## What is packaged

The `antigravity` binary from the tarball, installed as `bin/agy`, with its ELF
interpreter patched by `autoPatchelfHook`. It links only glibc, so the closure
is the binary and glibc. The build runs `agy --version` as its install check;
that needs no network and no login.

### No `SSH_CONNECTION` wrapper

The community recipe for this CLI wraps `agy` to set
`SSH_CONNECTION="127.0.0.1 12345 127.0.0.1 22"`. This flake does not. `agy`
reads that variable (it is one of the environment variables the binary
inspects), but `--version` and `--help` behave identically with it set and
unset, so it is not needed for the binary to run. Setting it unconditionally
would also overwrite the real value inside a genuine SSH session and make the
CLI believe it is always remote. If your login flow needs it, set it yourself
in the shell you launch `agy` from.

## Development

```bash
nix develop                   # curl, jq, tar, shellcheck, nixfmt
nix flake check               # builds the package, runs shellcheck, checks the pin
./scripts/update.sh           # regenerate sources.json (downloads both tarballs)
./scripts/update.sh --check   # exit non-zero if a newer release exists
./scripts/update.sh --force   # re-download and rewrite even when already current
```

## License

The packaging in this repository is MIT. The Antigravity CLI itself is
proprietary Google software, covered by Google's own terms. This repository
redistributes no Google binaries; it records where to fetch them and what they
should hash to.
