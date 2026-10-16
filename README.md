# roux

A Roc platform for hypermedia apps. An app (Roc handlers, typed templates, typed SQL on SQLite)
builds into one static executable that you copy to a server and run, with nothing in front. It runs
on [fourneau](https://github.com/Eldhus/fourneau), each request a Roc handler on a fiber; templates
compile to bytecode, so a markup edit reaches the browser in milliseconds under `roux dev`. Editor
support: [rocstache](https://github.com/Eldhus/rocstache).

A *roux* (said "roo") is the base every sauce starts from.


## Use it

Start from [roux-tutor](https://github.com/Eldhus/roux-tutor): clone it and run `./roux dev
main.roc`; it fetches roux and the Roc compiler it needs. By hand, take `roux` from the
[latest release](https://github.com/Eldhus/roux/releases/latest) (`roux version` names the Roc
nightly it needs); its notes give the line that names the platform in your app's header.

```sh
roux dev main.roc     # served, rebuilt as you save
roux build main.roc   # the executable, beside it
```

x86-64 Linux 6.7 or later, on an x86-64-v3 CPU (AVX2).


## The road ahead

- Multipart uploads, file responses.
- `shutdown!`
- A developer tool under `/_dev`.
- Migrations.
- Roc hot reload: a Roc edit served without a restart, as a markup edit already is.
- Data-driven routing: routes declared as data, and routers that compose. More structure in routing
  makes a large app easier to understand.
- Pub/sub: a publish needs no request, a gap is told, a slow reader never slows a publisher.
- A simulated disk, so SQLite runs under fourneau's simulator.


## Working on it

roux builds against fourneau checked out beside it:

```sh
git clone https://github.com/Eldhus/fourneau ../fourneau
zig build platform tools   # the host and roux
zig build test             # tidy and every test
```

To build an app against the checkout, the platform also needs musl's `crt1.o` and `libc.a`, from
Roc's source at the commit `toolchain.json` pins, each checked against its SHA-256 there:

```sh
c=$(jq -r .roc_musl.commit toolchain.json)
mkdir -p platform/targets/x64musl
for f in crt1.o libc.a; do
    curl -fsSL -o platform/targets/x64musl/$f \
        https://raw.githubusercontent.com/roc-lang/roc/$c/test/fx/platform/targets/x64musl/$f
done
jq -r '.roc_musl.files | to_entries[] | "\(.value)  platform/targets/x64musl/\(.key | split("/") | last)"' \
    toolchain.json | sha256sum -c
```

Zig and the Roc nightly are pinned in `.zig-version`, `.roc-version` and `toolchain.json`.


## Security

Report a problem by a private security advisory on GitHub, not an issue; see
[SECURITY.md](SECURITY.md).


## License

MIT. `host/roc_platform_abi.zig` and `vendor/roc-glue/` are Roc's (Universal Permissive License);
`vendor/sqlite/` is SQLite's (public domain); a release carries musl (MIT).

Part of [Eldhus](https://github.com/Eldhus).
