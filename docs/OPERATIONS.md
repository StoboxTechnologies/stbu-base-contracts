# Operations

What can be done with these contracts and this repository: build the sources, check the live contracts, and which administrative functions exist. Nothing here broadcasts a transaction.

## Scope

- This repository holds sources only. There is no deployment script, no test suite and no service code here.
- The contracts are deployed and immutable. Editing a file in this repository changes nothing on chain.
- Owner: Stobox Technologies Inc. Vulnerability reports: [Security](../README.md#security).

## Build and reproduce

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.2.0 --no-git
forge build            # compiles 29 files with solc 0.8.28 (this repository plus OpenZeppelin)
forge build --force    # ignore the cache and recompile
```

`forge build` prints style notes about immutable names (`token`, `predecessor`). They are lint notes, not errors, and the sources are not changed to silence them, because they mirror the verified on-chain code.

Settings come from `foundry.toml`: EVM `cancun`, optimizer 10,000 runs, `bytecode_hash = "none"`, `cbor_metadata = false`. Import `@openzeppelin/contracts/` maps to `lib/openzeppelin-contracts/contracts/` through `remappings.txt`. `lib/`, `out/` and `cache/` are git-ignored.

Comparing your build with the chain: the creation and runtime code differ only where the ERC-20 permit (EIP-712) immutables depend on the deployed address. The BaseScan source verification remains the integrity proof.

## Read-only checks of the live contracts

Any Base RPC endpoint works; the public one is used here. These commands only read.

```bash
B=https://mainnet.base.org
T=0xe0c0F44A84CC4a60206360006ebA237a5e8fC2dd   # STBUToken
C=0xec5B3e512de13cb5DdFD84B2DF3167230F2e66a4   # MigrationClaim

cast code $T --rpc-url $B | wc -c                          # non-trivial length: contract code exists
cast call $T 'name()(string)' --rpc-url $B                 # "Stobox Token"
cast call $T 'symbol()(string)' --rpc-url $B               # "STBU"
cast call $T 'decimals()(uint8)' --rpc-url $B              # 18
cast call $T 'MAX_SUPPLY()(uint256)' --rpc-url $B          # 250000000000000000000000000
cast call $T 'totalSupply()(uint256)' --rpc-url $B         # live value, grows with claims
cast call $T 'paused()(bool)' --rpc-url $B
cast call $T 'hasRole(bytes32,address)(bool)' $(cast keccak CLAIM_ROLE) $C --rpc-url $B   # true

cast call $C 'token()(address)' --rpc-url $B               # equals $T
cast call $C 'predecessor()(address)' --rpc-url $B         # 0x0000000000000000000000000000000000000000
cast call $C 'claimStart()(uint64)' --rpc-url $B           # 1789430400, 2026-09-15 00:00 UTC
cast call $C 'activeVoucherVersion()(uint16)' --rpc-url $B # 1 (the value read on 2026-10-16)
cast call $C 'totalClaimed()(uint256)' --rpc-url $B        # live value
cast call $C 'paused()(bool)' --rpc-url $B
cast call $C 'VOUCHER_TYPEHASH()(bytes32)' --rpc-url $B    # matches the next line
cast keccak 'MigrationVoucher(address wallet,uint256 cumulativeAmount,uint256 deadline,uint256 nonce,uint256 chainId,uint16 version)'
```

Role membership is not enumerable in `AccessControl`. To see who holds a role, check a known address with `hasRole(role, account)` or read the `RoleGranted` and `RoleRevoked` logs of the contract. `DEFAULT_ADMIN_ROLE` is `0x00…00`; the other role ids are `keccak256("CLAIM_ROLE")` and `keccak256("PAUSER_ROLE")`.

A wallet's state: `claimedOf(wallet)` (lifetime minted), `lastNonceOf(wallet)` (highest accepted voucher nonce), and `claimableFor(wallet, cumulativeAmount)` (what a voucher with that total would mint now; it does not check a signature).

## Administrative functions

Executed by the holders of the roles on chain; this repository contains no scripts for them.

| Contract | Function | Role | Effect | Limits |
|---|---|---|---|---|
| `MigrationClaim` | `pause()` | `PAUSER_ROLE` | Stops `claim` | Pauser can only pause |
| `MigrationClaim` | `unpause()` | `DEFAULT_ADMIN_ROLE` | Resumes `claim` | |
| `MigrationClaim` | `setSigner(signer, registered)` | `DEFAULT_ADMIN_ROLE` | Registers or removes a voucher signer; emits `SignerSet` | Zero address rejected; several signers can be active during a rotation |
| `MigrationClaim` | `setActiveVoucherVersion(v)` | `DEFAULT_ADMIN_ROLE` | Vouchers signed under any other version stop being accepted at once; emits `VoucherVersionSet` | |
| `MigrationClaim` | `setClaimStart(t)` | `DEFAULT_ADMIN_ROLE` | Reschedules the claim window start; emits `ClaimStartSet` | Only before the current start has passed, never into the past |
| `STBUToken` | `pause()` | `PAUSER_ROLE` | Stops all transfers, mints and burns, so claims also fail | `PAUSER_ROLE` is granted by the admin after deployment |
| `STBUToken` | `unpause()` | `DEFAULT_ADMIN_ROLE` | Resumes transfers, mints and burns | |
| both | `grantRole`, `revokeRole` | `DEFAULT_ADMIN_ROLE` (the admin of every role) | OpenZeppelin `AccessControl` role management | Replacing the claim contract means revoking `CLAIM_ROLE` from the old one and granting it to the new one |
| both | `renounceRole(role, account)` | The holder of the role, for itself | Gives the role up | |

Pause order for an incident: pausing `MigrationClaim` stops new claims and leaves transfers alone; pausing `STBUToken` also freezes transfers and burns. Both can be paused by a pauser key; only the admin can resume.

## Changing this repository

- The two Solidity files mirror the BaseScan-verified source. Do not edit them, not even for comments or formatting; the code on chain cannot follow.
- Documentation, build settings and the changelog may change through a pull request against `main`. Bump [VERSION](../VERSION) and add an entry to [CHANGELOG.md](../CHANGELOG.md) in the same pull request.
- Tags are annotated and cut after merge: `git tag -a vX.Y.Z -m "..."` then `git push origin vX.Y.Z`.

Related: [README](../README.md) · [ARCHITECTURE.md](ARCHITECTURE.md)
