# Archive: the previous README

Kept so that nothing is lost when the README was rewritten to the Stobox documentation standard (2026-10-16). The still-valid content is carried into the new README and into ARCHITECTURE.md and OPERATIONS.md.

The text below is the README as it stood at `HEAD`, unchanged except that long dashes were turned into en dashes. It is a historical record: statements in it may be out of date, and the current README and the other files in `docs/` take precedence.

---

# STBU on Base: contracts

Source code of the canonical Stobox Token (STBU) on [Base](https://base.org) (chain 8453) and the migration claim contract that mints it.

| Contract | Address | Source verified |
|---|---|---|
| `STBUToken` | [`0xe0c0F44A84CC4a60206360006ebA237a5e8fC2dd`](https://basescan.org/address/0xe0c0f44a84cc4a60206360006eba237a5e8fc2dd) | BaseScan |
| `MigrationClaim` | [`0xec5B3e512de13cb5DdFD84B2DF3167230F2e66a4`](https://basescan.org/address/0xec5b3e512de13cb5ddfd84b2df3167230f2e66a4) | BaseScan |

## What the contracts do

- **`STBUToken`**: ERC-20 with burn, permit (EIP-2612), pause and role-based access. Maximum supply is fixed at 250,000,000 STBU. The only way to mint is the claim contract, which holds `CLAIM_ROLE`. No proxy, no owner mint, no cap change. Supply was zero at deployment.
- **`MigrationClaim`**: mints STBU on Base against verified burns of legacy STBU, using EIP-712 vouchers from a registered signer, per-wallet nonces and cumulative claim accounting. Pausable, with a start-time gate.

Public claiming opened on 15 September 2026. Details for holders: [stobox.io/stbu](https://www.stobox.io/stbu).

## Build parameters

solc 0.8.28 · EVM cancun · optimizer 10,000 runs · OpenZeppelin Contracts v5.2.0 · CREATE2 deployment through the standard deterministic deployer.

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.2.0 --no-git
forge build
```

A raw bytecode comparison against the chain differs only in the ERC-20 permit (EIP-712) immutables, which depend on the deployed address. The BaseScan source verification is the integrity proof.

## Related

- Stobox DID registry: [Stobox-Decentralized-ID](https://github.com/StoboxTechnologies/Stobox-Decentralized-ID)
- STV3 protocol: [Stobox_STV3_Protocol](https://github.com/StoboxTechnologies/Stobox_STV3_Protocol)
- Security: [stobox.io/stbu/security](https://www.stobox.io/stbu/security)

## Disclaimer

Reference code published for transparency. It is not an offer, and it is not legal, tax or investment advice.

License: MIT.
