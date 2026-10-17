# Changelog

All notable changes to this repository. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow [Semantic Versioning](https://semver.org/). The version labels the sources and documentation in this repository; the deployed contracts are immutable and are not versioned by it.

## [Unreleased]

## [0.1.0] - 2026-10-16

First tagged state of the repository: the sources as published on 2026-10-03, plus documentation.

### Added

- `docs/ARCHITECTURE.md`: the claim flow, voucher format, checks in order, roles, what can and cannot change, events and errors.
- `docs/OPERATIONS.md`: build and reproduce, read-only checks of the live contracts, the administrative functions and their limits.
- `docs/ARCHIVE.md`: the previous README, kept verbatim.
- `CHANGELOG.md` and `VERSION`.

### Changed

- `README.md` rewritten to the Stobox documentation standard (status, where it runs, architecture, layout, quick start, versioning, security, licence).

### Unchanged

- `src/STBUToken.sol`, `src/MigrationClaim.sol`, `foundry.toml`, `remappings.txt` and `LICENSE` are untouched. The sources stay byte-identical to the BaseScan-verified code.

### Before 0.1.0

- 2026-10-03: initial publication of the `STBUToken` and `MigrationClaim` sources, BaseScan-verified (commit `626ff5f`).

[Unreleased]: https://github.com/StoboxTechnologies/stbu-base-contracts/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/StoboxTechnologies/stbu-base-contracts/releases/tag/v0.1.0
