# Combined Smart Contract Audit Package

**Submitted by:** Jin Gonzalez
**Date:** June 17, 2026
**Chain:** BSC (BNB Smart Chain)
**Solidity:** 0.8.20+
**Dependencies:** OpenZeppelin Contracts v5.x

---

## Project 1: TOTOZ.io — Utility & Governance Tokens

**Entity:** OZ Capital Corporation (BVI)
**Website:** totoz.io

| Contract | Lines | Purpose |
|----------|-------|---------|
| TOTOZToken.sol | ~210 | Consumptive utility token. 8 Quadrillion supply. Burned on AI agent use. |
| OZT.sol | ~140 | Advisory governance token. 1 Billion supply. 1 OZT = 1 vote. |
| BurnSchedule.sol | ~190 | Two-phase burn: 90% trustless (anyone calls) + 5% discretionary. |

**Subtotal: 3 contracts, ~540 lines**

Key features to audit:
- Trustless burn (Phase 1: no role check for months 0-40)
- Burn source restriction (burnFrom only targets designated wallet)
- Daily per-user burn cap (1M tokens/day)
- Burn floors (1B TOTOz, 10M OZT)
- Ownership role sync (_transferOwnership syncs DEFAULT_ADMIN_ROLE)
- Batch airdrop/distribute with duplicate checks
- Pause on both tokens
- renounceRole blocked for DEFAULT_ADMIN_ROLE

---

## Project 2: Presello — Decentralized Marketplace Vault

**Entity:** Presello LLC (Montana, USA)
**Website:** presello.io

| Contract | Lines | Purpose |
|----------|-------|---------|
| Vault.sol | ~326 | Non-custodial escrow vault for token marketplace |
| VaultGovernance.sol | ~595 | 2-of-3 multisig governance, timelocks, emergency controls |
| VaultTypes.sol | ~56 | Shared type definitions and structs |

**Subtotal: 3 contracts, ~977 lines**

Key features to audit:
- 2-of-3 multisig for all governance actions
- Token allowlist (only approved tokens can be deposited)
- Daily withdrawal caps per token
- Large withdrawal timelock (24 hours)
- Backend address change timelock (24 hours)
- Signer rotation timelock (7 days)
- Emergency pause (1 signer to pause, 2-of-3 to unpause)
- Emergency withdrawal to safe address (72 hours)
- Token rescue for stuck tokens (24 hours)
- Batch releases (max 50 per call)
- Fee-on-transfer token safety (balance-delta pattern)
- ReentrancyGuard on all external calls

Test results: 68 tests passing (see presello/tests/)
Static analysis: Slither results included (see presello/slither-results.txt)

---

## Combined Total

**6 contracts, ~1,517 lines of custom Solidity**

Both projects deploy on BSC (BEP-20) using OpenZeppelin v5.x.
Separate audit reports requested for each project.

---

## Package Contents

```
combined-audit-package/
├── README.md (this file)
├── totoz/
│   ├── TOTOZToken.sol
│   ├── OZT.sol
│   └── BurnSchedule.sol
├── presello/
│   ├── Vault.sol
│   ├── VaultGovernance.sol
│   ├── VaultTypes.sol
│   ├── tests/
│   │   ├── Vault.test.js
│   │   ├── VaultGovernance.test.js
│   │   ├── MockERC20.sol
│   │   ├── FeeOnTransferMockERC20.sol
│   │   └── hardhat.config.js
│   └── slither-results.txt
```

All source code is included in this package. No external access required.

---

## Contact

**Project Owner:** Jin Gonzalez
**Email:** jin@ozcapital.io
