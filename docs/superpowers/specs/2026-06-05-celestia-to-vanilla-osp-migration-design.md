# Celestia → Vanilla OSP Migration Action

**Date:** 2026-06-05
**Status:** Approved (design)

## Problem

When a chain is migrated from vanilla DA to Celestia DA via
`CelestiaNitroContracts2Point1Point3UpgradeAction`, that action upgrades the
`ChallengeManager` to point at a Celestia-aware `OneStepProofEntry` (the
"celestia OSP"). Reversing a Celestia migration back to vanilla requires undoing
this: the `ChallengeManager` must be pointed back at the vanilla consensus-v32
OSP, otherwise the fraud-proof path is adjudicated by the celestia OSP while the
machine runs the vanilla wasm root — an unsound state that normal chain health
(sequencing, batch posting, assertions) never exercises.

This is currently only doable by hand-assembling
`executeCall → upgradeAndCall → postUpgradeInit` calldata for the owner Safe.
This spec packages that as a reusable orbit-action.

## Scope

**In scope:** swap the `ChallengeManager` OSP from celestia back to vanilla
consensus-v32, with conditional routing (`condRoot`/`condOsp`) that preserves any
in-flight challenge still anchored at the celestia root.

**Explicitly out of scope** (decided during brainstorming):
- No wasm-module-root change. The root flip is handled separately.
- No Inbox / SequencerInbox upgrade. That is the separate
  `NitroContracts2Point1Point3UpgradeAction`.
- No precondition asserting the live root equals the celestia root (it would
  block chains whose root has already been flipped to vanilla).

## Design

### Contract: `VanillaOspMigrationNitroContracts2Point1Point0UpgradeAction.sol`

Location: `contracts/parent-chain/contract-upgrades/VanillaOspMigrationNitroContracts2Point1Point0UpgradeAction.sol`

Immutables:
- `address newChallengeManagerImpl` — vanilla v2.1.0 `ChallengeManager` impl
- `IOneStepProofEntry osp` — vanilla consensus-v32 `OneStepProofEntry`
- `bytes32 condRoot` — the celestia wasm root (`0xe81f986823a85105c5fd91bb53b4493d38c0c26652d23f76a7405ac889908287`)

Reuses the existing `IChallengeManagerUpgradeInit` interface imported from
`CelestiaNitroContracts2Point1Point0UpgradeAction.sol`:

```solidity
function postUpgradeInit(IOneStepProofEntry osp_, bytes32 condRoot, IOneStepProofEntry condOsp) external;
function osp() external returns (address);
```

Constructor performs `Address.isContract` checks on `newChallengeManagerImpl`
and `osp`, and `require(condRoot != bytes32(0))`.

`perform(IRollupCore rollup, ProxyAdmin proxyAdmin)`:
1. `challengeManager = rollup.challengeManager()` (as `TransparentUpgradeableProxy`).
2. Read the **live** installed OSP: `condOsp = IOneStepProofEntry(IChallengeManagerUpgradeInit(challengeManager).osp())`.
   This is the celestia OSP, read at execution time — the "read live from chain"
   choice, done at perform-time so it always reflects the truly-current OSP with
   no deploy-time or env coupling.
3. `require(address(condOsp) != address(osp), "OSP already vanilla")` — guard
   against double-run / already-migrated chains.
4. `proxyAdmin.upgradeAndCall(challengeManager, newChallengeManagerImpl,
   abi.encodeCall(IChallengeManagerUpgradeInit.postUpgradeInit, (osp, condRoot, condOsp)))`.
5. Verify: `proxyAdmin.getProxyImplementation(challengeManager) == newChallengeManagerImpl`
   and `IChallengeManagerUpgradeInit(challengeManager).osp() == address(osp)`.

Resulting `getOsp` behavior:
- celestia root (`condRoot`) → celestia OSP (`condOsp`) — in-flight challenge safety
- any other root (vanilla) → vanilla OSP (`osp`)

### Deploy script: `DeployVanillaOspMigrationNitroContracts2Point1Point0UpgradeAction.s.sol`

Location: `scripts/foundry/contract-upgrades/vanilla-osp-migration/`

Extends `DeploymentHelpersScript`. Etches `MockArbSys` at `address(100)` when
`PARENT_CHAIN_IS_ARBITRUM=true`. Under `vm.startBroadcast()`:
- Deploy vanilla OSP suite from `@arbitrum/nitro-contracts-2.1.0`:
  `OneStepProver0`, `OneStepProverMemory`, `OneStepProverMath`, and the **vanilla**
  `OneStepProverHostIo` (NOT the celestia variant), then assemble
  `OneStepProofEntry(prover0, memory, math, hostio)`.
- Deploy vanilla `ChallengeManager` impl from `@arbitrum/nitro-contracts-2.1.0`.
- Deploy `VanillaOspMigrationNitroContracts2Point1Point0UpgradeAction(
  newChallengeManagerImpl, osp, CELESTIA_WASM_MODULE_ROOT)`.

`CELESTIA_WASM_MODULE_ROOT` is a script constant
`0xe81f986823a85105c5fd91bb53b4493d38c0c26652d23f76a7405ac889908287`.
No chain reads needed (condOsp is read at perform-time).

### Execute script: `ExecuteVanillaOspMigrationNitroContracts2Point1Point0Upgrade.s.sol`

Mirrors `ExecuteNitroContracts2Point1Point0Upgrade.s.sol`:
- Env: `UPGRADE_ACTION_ADDRESS`, `INBOX_ADDRESS`, `PROXY_ADMIN_ADDRESS`,
  `PARENT_UPGRADE_EXECUTOR_ADDRESS`.
- Derive `rollup = IRollupCore(inbox.bridge().rollup())`.
- `upgradeCalldata = abi.encodeCall(perform, (rollup, proxyAdmin))`.
- `IUpgradeExecutor(executor).execute(action, upgradeCalldata)`.
- Without `--broadcast`, prints the payload usable for a multisig executor.
- Post-check: `IChallengeManagerUpgradeInit(rollup.challengeManager()).osp() == action.osp()`.

### Docs & config

- `README.md` describing what the action does, requirements, and the
  deploy/execute flow (modeled on the celestia-2.1.3 README).
- `.env.sample` with `PARENT_CHAIN_IS_ARBITRUM`, `UPGRADE_ACTION_ADDRESS`,
  `INBOX_ADDRESS`, `PROXY_ADMIN_ADDRESS`, `PARENT_UPGRADE_EXECUTOR_ADDRESS`.

## Files

- `contracts/parent-chain/contract-upgrades/VanillaOspMigrationNitroContracts2Point1Point0UpgradeAction.sol` (new)
- `scripts/foundry/contract-upgrades/vanilla-osp-migration/DeployVanillaOspMigrationNitroContracts2Point1Point0UpgradeAction.s.sol` (new)
- `scripts/foundry/contract-upgrades/vanilla-osp-migration/ExecuteVanillaOspMigrationNitroContracts2Point1Point0Upgrade.s.sol` (new)
- `scripts/foundry/contract-upgrades/vanilla-osp-migration/README.md` (new)
- `scripts/foundry/contract-upgrades/vanilla-osp-migration/.env.sample` (new)

## Verification

- `forge build` compiles all new files.
- Manual/fork sanity (optional, follow-up): on a celestia-migrated fork, run
  deploy + execute and confirm `challengeManager.osp()` returns the vanilla OSP,
  `getOsp(vanillaRoot)` → vanilla, `getOsp(celestiaRoot)` → celestia.
