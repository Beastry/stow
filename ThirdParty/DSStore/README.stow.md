# Stow's DSStore dependency

Upstream: <https://github.com/sindresorhus/DSStore>

Base: tag `1.0.0`, commit `6dc395837c3dc371f9c3e71794fab719db74c17a`.
The package manifest, source files, tests and fixture are copied from that commit; `license`
contains the original MIT license. Stow uses this local Swift package through `project.yml`.

## Local compatibility patch

`Sources/DSStore/DSStore.swift` removes the `traverseNode` assumption that every allocation is at
most the nominal 4096-byte page size. Real installer images, including OpenWhispr 1.5.5 arm64,
Obsidian and Typeless, contain 8192-byte leaf allocations while declaring a 4096-byte page size
in the tree header. This is independent of the logical page-size field.
Upstream tag `1.1.0` (commit `c6a9d28a8fc60b4eba0cfc667111e8d4c7cda356`) retained the same
restriction when checked on 2026-11-09.

The patch retains allocator address/alignment checks, full-file bounds, per-node record bounds,
cycle/depth protection, and tree count validation. It performs no additional allocation based on
the node size. Stow separately limits `.DS_Store` input to 4 MiB before parsing. Serialization is
unchanged and continues to write nodes of at most one page.

Upstream tests are retained unchanged. Stow's `InstallerStoreCompatibilityTests` supplies
synthetic 8 KiB and 16 KiB nodes and checks malformed lengths, addresses, records and cycles.
Real third-party installer metadata remains outside the repository.

Run upstream checks with `swift test --package-path ThirdParty/DSStore`.
Replace this copy with a pinned upstream dependency once an upstream release supports these
allocations and passes both suites.
