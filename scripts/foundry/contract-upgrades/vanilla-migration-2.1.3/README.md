# Vanilla migration (reverse a Celestia migration) — 2.1.3

These scripts deploy and execute `VanillaMigrationNitroContracts2Point1Point3UpgradeAction`, which
reverses a Celestia migration back to vanilla in a **single atomic transaction**. It is the mirror
image of `CelestiaNitroContracts2Point1Point3UpgradeAction`.

`perform()` does all of the following in one call:

1. Upgrade the `SequencerInbox` (eth or erc20) to the vanilla `v2.1.3` implementation.
2. Upgrade the `Inbox` / `ERC20Inbox` contract to the vanilla `v2.1.3` implementation.
3. Swap the `ChallengeManager` to the vanilla consensus-v32 OSP via
   `postUpgradeInit(vanillaOsp, condRoot, condOsp)`, where `condRoot` is the celestia wasm root and
   `condOsp` is the celestia OSP read live from the ChallengeManager at execution time. In-flight
   challenges still anchored at the celestia root keep using the celestia OSP.
4. Set the vanilla consensus-v32 wasm module root
   (`0x184884e1eb9fefdc158f6c8ac912bb183bf3cf83f0090317e0bc4ac5860baa39`).

Because it runs through `UpgradeExecutor.execute(action, ...)`, the whole migration is **one**
multisig/Safe transaction.

## Requirements / preconditions

- The chain must currently be **on the celestia wasm root**
  (`0xe81f986823a85105c5fd91bb53b4493d38c0c26652d23f76a7405ac889908287`). `perform()` reverts with
  `wasm root mismatch` otherwise — i.e. this is for a chain still fully on Celestia. (A chain that
  has already been partially reverted by hand is not a valid target.)
- The bridge must not be an `ERC20Bridge` below `v2.x.x` (reverts otherwise).

## How to use it

1. Setup `.env` according to `.env.sample`. The `.env` file must be in the project root.

> [!CAUTION]
> The .env file must be in project root.

> [!NOTE]
> The OSP and ChallengeManager impl are stateless logic contracts shared across chains. If vanilla
> consensus-v32 instances already exist on your parent chain (e.g. from a 2.1.0 upgrade action), set
> `OSP_ADDRESS` and `CHALLENGE_MANAGER_IMPL_ADDRESS` to reuse them; the script then only deploys the
> Inbox/SequencerInbox impls and the action. The Inbox/SequencerInbox impls are always deployed
> fresh (they are constructed with chain-specific args).

2. Deploy the impls + action:

```bash
forge script --sender $DEPLOYER --rpc-url $PARENT_CHAIN_RPC --broadcast --slow DeployVanillaMigrationNitroContracts2Point1Point3UpgradeActionScript -vvv --verify --skip-simulation
# use --account XXX / --private-key XXX / --interactive / --ledger to set the sending account
```

The last deployed address is the upgrade action — set it as `UPGRADE_ACTION_ADDRESS` in `.env`.

3. Execute with the account that has executor rights on the parent chain `UpgradeExecutor` (the
   rollup owner):

```bash
forge script --sender $EXECUTOR --rpc-url $PARENT_CHAIN_RPC --broadcast ExecuteVanillaMigrationNitroContracts2Point1Point3UpgradeScript -vvv
# use --account XXX / --private-key XXX / --interactive / --ledger to set the sending account
```

If your executor is a multisig/Safe, run the above **without** `--broadcast` to get the payload for
the multisig transaction (a single `execute(action, calldata)` call to the UpgradeExecutor).

4. Verify:

```bash
ROLLUP=$(cast call --rpc-url $PARENT_CHAIN_RPC $SEQ_INBOX "rollup()(address)")
CM=$(cast call --rpc-url $PARENT_CHAIN_RPC $ROLLUP "challengeManager()(address)")
# vanilla root
cast call --rpc-url $PARENT_CHAIN_RPC $ROLLUP "wasmModuleRoot()(bytes32)"
# vanilla OSP
cast call --rpc-url $PARENT_CHAIN_RPC $CM "osp()(address)"
# vanilla root -> vanilla OSP ; celestia root -> celestia OSP
cast call --rpc-url $PARENT_CHAIN_RPC $CM "getOsp(bytes32)(address)" 0x184884e1eb9fefdc158f6c8ac912bb183bf3cf83f0090317e0bc4ac5860baa39
cast call --rpc-url $PARENT_CHAIN_RPC $CM "getOsp(bytes32)(address)" 0xe81f986823a85105c5fd91bb53b4493d38c0c26652d23f76a7405ac889908287
```

## FAQ

### Q: intrinsic gas too low when running foundry script

A: try adding `-g 1000` to the command.
