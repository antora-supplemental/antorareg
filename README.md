<div align="center">

# antorareg

**Install Antora 3 UI bundles and extensions from the Antora Extensions Registry, with a lockfile.**

[![CI](https://github.com/antora-supplemental/antorareg/actions/workflows/ci.yml/badge.svg)](https://github.com/antora-supplemental/antorareg/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Explore the docs](docs/modules/ROOT/pages/index.adoc) · [Registry](https://registry.antora-supplemental.org) · [Report a bug](https://github.com/antora-supplemental/antorareg/issues)

</div>

## About

`antorareg` edits `antora-playbook.yml` in place to add, update and remove packages from the [Antora Extensions Registry](https://registry.antora-supplemental.org). Packages are fetched into a gitignored `.antorareg/cache`, and `antorareg.lock` pins every version, commit and file hash.

- Antora 3 only. It never wraps or runs the `antora` CLI.
- Byte-for-byte playbook edits through [yaml-edit-d](https://github.com/dlang-supplemental/yaml-edit-d). No marker comments.
- `verify` catches drift, corrupted caches, and committed or edited copies of package files.
- `migrate` moves hand-copied package files under the lockfile.

### Built with

D, [LDC](https://github.com/ldc-developers/ldc), [DUB](https://dub.pm) and yaml-edit-d.

## Usage

```console
antorareg init
antorareg install "asset fingerprint"
antorareg verify
antorareg update
antorareg eject asset-fingerprint
antorareg migrate --dry-run
```

In GitHub Actions:

```yaml
- uses: antora-supplemental/antorareg@v0
  with:
    playbook: antora-playbook.yml
```

## Building

DUB fetches [yaml-edit](https://code.dlang.org/packages/yaml-edit) from the registry.

```console
dub test --compiler=ldc2
dub build --compiler=ldc2 -b release
```

### Testing against a local yaml-edit-d checkout

Register the checkout so DUB prefers it over the registry copy (its version comes from its git tag, so it must satisfy `~>0.1.0`):

```console
dub add-local ../../dlang-supplemental/yaml-edit-d
dub test --compiler=ldc2
```

Undo with `dub remove-local ../../dlang-supplemental/yaml-edit-d`. Do not use the deprecated `dub add-override`.

## License

MIT. See [LICENSE](LICENSE).
