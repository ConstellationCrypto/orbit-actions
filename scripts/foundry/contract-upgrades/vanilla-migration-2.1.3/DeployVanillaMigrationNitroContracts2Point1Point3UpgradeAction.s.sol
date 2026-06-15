// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import { DeploymentHelpersScript } from '../../helper/DeploymentHelpers.s.sol';
import { VanillaMigrationNitroContracts2Point1Point3UpgradeAction, IOneStepProofEntry } from '../../../../contracts/parent-chain/contract-upgrades/VanillaMigrationNitroContracts2Point1Point3UpgradeAction.sol';
import { MockArbSys } from '../../helper/MockArbSys.sol';

/**
 * @title DeployVanillaMigrationNitroContracts2Point1Point3UpgradeActionScript
 * @notice Deploys the vanilla v2.1.3 Inbox/SequencerInbox impls, (optionally) the vanilla
 *         consensus-v32 OSP + ChallengeManager impl, and the
 *         VanillaMigrationNitroContracts2Point1Point3UpgradeAction that reverses a Celestia
 *         migration back to vanilla in a single atomic action.
 */
contract DeployVanillaMigrationNitroContracts2Point1Point3UpgradeActionScript is
  DeploymentHelpersScript
{
  // vanilla consensus-v32 (ArbOS32 bianca) wasm module root that the chain is migrated TO
  bytes32 public constant WASM_MODULE_ROOT =
    0x184884e1eb9fefdc158f6c8ac912bb183bf3cf83f0090317e0bc4ac5860baa39;

  // celestia wasm module root the chain is migrated FROM; kept as condRoot so in-flight challenges
  // anchored here are routed to the live (celestia) OSP after the swap
  // https://github.com/celestiaorg/nitro/releases/tag/v3.2.1-rc.1
  bytes32 public constant COND_WASM_MODULE_ROOT =
    0xe81f986823a85105c5fd91bb53b4493d38c0c26652d23f76a7405ac889908287;

  function run() public {
    bool isArbitrum = vm.envBool('PARENT_CHAIN_IS_ARBITRUM');
    if (isArbitrum) {
      // etch a mock ArbSys contract so that foundry simulates it nicely
      bytes memory mockArbSysCode = address(new MockArbSys()).code;
      vm.etch(address(100), mockArbSysCode);
    }

    // Reuse existing vanilla consensus-v32 logic contracts if provided (e.g. the OSP +
    // ChallengeManager impl already deployed by a 2.1.0 upgrade action on this parent chain).
    // These are stateless and safe to share. Leave unset/zero to deploy them fresh.
    address existingOsp = vm.envOr('OSP_ADDRESS', address(0));
    address existingChallengeManagerImpl = vm.envOr(
      'CHALLENGE_MANAGER_IMPL_ADDRESS',
      address(0)
    );

    vm.startBroadcast();

    // vanilla osp from v2.1.0 (consensus-v32): reuse if provided, else deploy fresh
    address newOsp = existingOsp;
    if (newOsp == address(0)) {
      address osp0 = deployBytecodeFromJSON(
        '/node_modules/@arbitrum/nitro-contracts-2.1.0/build/contracts/src/osp/OneStepProver0.sol/OneStepProver0.json'
      );
      address ospMemory = deployBytecodeFromJSON(
        '/node_modules/@arbitrum/nitro-contracts-2.1.0/build/contracts/src/osp/OneStepProverMemory.sol/OneStepProverMemory.json'
      );
      address ospMath = deployBytecodeFromJSON(
        '/node_modules/@arbitrum/nitro-contracts-2.1.0/build/contracts/src/osp/OneStepProverMath.sol/OneStepProverMath.json'
      );
      address ospHostIo = deployBytecodeFromJSON(
        '/node_modules/@arbitrum/nitro-contracts-2.1.0/build/contracts/src/osp/OneStepProverHostIo.sol/OneStepProverHostIo.json'
      );

      newOsp = deployBytecodeWithConstructorFromJSON(
        '/node_modules/@arbitrum/nitro-contracts-2.1.0/build/contracts/src/osp/OneStepProofEntry.sol/OneStepProofEntry.json',
        abi.encode(osp0, ospMemory, ospMath, ospHostIo)
      );
    }

    // vanilla challenge manager impl from v2.1.0: reuse if provided, else deploy fresh
    address challengeManager = existingChallengeManagerImpl;
    if (challengeManager == address(0)) {
      challengeManager = deployBytecodeFromJSON(
        '/node_modules/@arbitrum/nitro-contracts-2.1.0/build/contracts/src/challenge/ChallengeManager.sol/ChallengeManager.json'
      );
    }

    address reader4844Address;
    if (!isArbitrum) {
      // deploy blob reader
      reader4844Address = deployBytecodeFromJSON(
        '/node_modules/@arbitrum/nitro-contracts-2.1.3/out/yul/Reader4844.yul/Reader4844.json'
      );
    }

    // deploy new ETHInbox contract from vanilla v2.1.3
    address newEthInboxImpl = deployBytecodeWithConstructorFromJSON(
      '/node_modules/@arbitrum/nitro-contracts-2.1.3/build/contracts/src/bridge/Inbox.sol/Inbox.json',
      abi.encode(vm.envUint('MAX_DATA_SIZE'))
    );
    // deploy new ERC20Inbox contract from vanilla v2.1.3
    address newERC20InboxImpl = deployBytecodeWithConstructorFromJSON(
      '/node_modules/@arbitrum/nitro-contracts-2.1.3/build/contracts/src/bridge/ERC20Inbox.sol/ERC20Inbox.json',
      abi.encode(vm.envUint('MAX_DATA_SIZE'))
    );

    // deploy new EthSequencerInbox contract from vanilla v2.1.3
    address newEthSeqInboxImpl = deployBytecodeWithConstructorFromJSON(
      '/node_modules/@arbitrum/nitro-contracts-2.1.3/build/contracts/src/bridge/SequencerInbox.sol/SequencerInbox.json',
      abi.encode(vm.envUint('MAX_DATA_SIZE'), reader4844Address, false)
    );

    // deploy new Erc20SequencerInbox contract from vanilla v2.1.3
    address newErc20SeqInboxImpl = deployBytecodeWithConstructorFromJSON(
      '/node_modules/@arbitrum/nitro-contracts-2.1.3/build/contracts/src/bridge/SequencerInbox.sol/SequencerInbox.json',
      abi.encode(vm.envUint('MAX_DATA_SIZE'), reader4844Address, true)
    );

    // deploy upgrade action
    new VanillaMigrationNitroContracts2Point1Point3UpgradeAction({
      _newEthInboxImpl: newEthInboxImpl,
      _newERC20InboxImpl: newERC20InboxImpl,
      _newEthSequencerInboxImpl: newEthSeqInboxImpl,
      _newERC20SequencerInboxImpl: newErc20SeqInboxImpl,
      _newWasmModuleRoot: WASM_MODULE_ROOT,
      _newChallengeManagerImpl: challengeManager,
      _osp: IOneStepProofEntry(newOsp),
      _condRoot: COND_WASM_MODULE_ROOT
    });

    vm.stopBroadcast();
  }
}
