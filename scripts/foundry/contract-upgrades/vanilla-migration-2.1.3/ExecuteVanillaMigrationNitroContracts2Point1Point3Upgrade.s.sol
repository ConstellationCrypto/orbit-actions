// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import 'forge-std/Script.sol';
import { VanillaMigrationNitroContracts2Point1Point3UpgradeAction, ProxyAdmin } from '../../../../contracts/parent-chain/contract-upgrades/VanillaMigrationNitroContracts2Point1Point3UpgradeAction.sol';
import { IInboxBase } from '@arbitrum/nitro-contracts-2.1.3/src/bridge/IInboxBase.sol';
import { IUpgradeExecutor } from '@offchainlabs/upgrade-executor/src/IUpgradeExecutor.sol';
import { ISequencerInbox } from '@arbitrum/nitro-contracts-2.1.3/src/bridge/ISequencerInbox.sol';
import { IRollupCore } from '@arbitrum/nitro-contracts-2.1.0/src/rollup/IRollupCore.sol';

/**
 * @title ExecuteVanillaMigrationNitroContracts2Point1Point3UpgradeScript
 * @notice Executes the vanilla migration (celestia -> vanilla: inbox + sequencer inbox + OSP +
 *         wasm module root) through the parent chain UpgradeExecutor, in a single transaction.
 */
contract ExecuteVanillaMigrationNitroContracts2Point1Point3UpgradeScript is Script {
  function run() public {
    // used to check upgrade was successful
    bytes32 wasmModuleRoot = vm.envBytes32('TARGET_WASM_MODULE_ROOT');

    VanillaMigrationNitroContracts2Point1Point3UpgradeAction upgradeAction = VanillaMigrationNitroContracts2Point1Point3UpgradeAction(
        vm.envAddress('UPGRADE_ACTION_ADDRESS')
      );

    address inbox = vm.envAddress('INBOX_ADDRESS');

    uint256 maxDataSize = vm.envUint('MAX_DATA_SIZE');
    require(
      ISequencerInbox(upgradeAction.newEthInboxImpl()).maxDataSize() ==
        maxDataSize ||
        ISequencerInbox(upgradeAction.newERC20InboxImpl()).maxDataSize() ==
        maxDataSize ||
        ISequencerInbox(upgradeAction.newEthSequencerInboxImpl())
          .maxDataSize() ==
        maxDataSize ||
        ISequencerInbox(upgradeAction.newERC20SequencerInboxImpl())
          .maxDataSize() ==
        maxDataSize,
      'MAX_DATA_SIZE mismatch with action'
    );
    require(
      IInboxBase(inbox).maxDataSize() == maxDataSize,
      'MAX_DATA_SIZE mismatch with current deployment'
    );

    IRollupCore rollup = IRollupCore(
      address(IInboxBase(inbox).bridge().rollup())
    );

    // prepare upgrade calldata
    ProxyAdmin proxyAdmin = ProxyAdmin(vm.envAddress('PROXY_ADMIN_ADDRESS'));
    bytes memory upgradeCalldata = abi.encodeCall(
      VanillaMigrationNitroContracts2Point1Point3UpgradeAction.perform,
      (rollup, address(inbox), proxyAdmin)
    );

    // execute the upgrade
    // action checks prerequisites, and script will fail if the action reverts
    IUpgradeExecutor executor = IUpgradeExecutor(
      vm.envAddress('PARENT_UPGRADE_EXECUTOR_ADDRESS')
    );

    // the single multisig/Safe transaction to submit: call execute(action, calldata) on the
    // UpgradeExecutor. Logged so it can be copied into a Safe / multisig directly.
    bytes memory executorCalldata = abi.encodeCall(
      IUpgradeExecutor.execute,
      (address(upgradeAction), upgradeCalldata)
    );
    console.log('--- multisig transaction ---');
    console.log('to (UpgradeExecutor):', address(executor));
    console.log('value: 0');
    console.log('data:');
    console.logBytes(executorCalldata);
    console.log('----------------------------');

    vm.startBroadcast();
    executor.execute(address(upgradeAction), upgradeCalldata);

    // sanity check, full checks are done on-chain by the upgrade action
    require(
      rollup.wasmModuleRoot() == upgradeAction.newWasmModuleRoot(),
      'Wasm module root not set'
    );
    require(
      rollup.wasmModuleRoot() == wasmModuleRoot,
      'Unexpected wasm module root set'
    );

    vm.stopBroadcast();
  }
}
