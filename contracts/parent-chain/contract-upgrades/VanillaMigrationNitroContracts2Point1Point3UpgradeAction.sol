// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import '@arbitrum/nitro-contracts-2.1.0/src/osp/IOneStepProofEntry.sol';
import '@arbitrum/nitro-contracts-2.1.0/src/rollup/IRollupAdmin.sol';
import '@arbitrum/nitro-contracts-2.1.0/src/rollup/IRollupCore.sol';
import { ProxyAdmin } from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import { TransparentUpgradeableProxy } from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import { Address } from '@openzeppelin/contracts/utils/Address.sol';

import { IChallengeManagerUpgradeInit } from './CelestiaNitroContracts2Point1Point0UpgradeAction.sol';

interface IInbox {
  function bridge() external view returns (address);
  function sequencerInbox() external view returns (address);
  function allowListEnabled() external view returns (bool);
}

interface IERC20Bridge {
  function nativeToken() external view returns (address);
}

interface IERC20Bridge_v2 {
  function nativeTokenDecimals() external view returns (uint8);
}

/**
 * @title   VanillaMigrationNitroContracts2Point1Point3UpgradeAction
 * @notice  Reverses a Celestia migration back to vanilla in a single atomic action:
 *            1. Upgrades the SequencerInbox (eth or erc20) to the vanilla v2.1.3 impl
 *            2. Upgrades the Inbox (eth or erc20) to the vanilla v2.1.3 impl
 *            3. Swaps the ChallengeManager to the vanilla consensus-v32 OSP, routing the
 *               celestia root to the previously-installed (celestia) OSP for in-flight challenges
 *            4. Sets the vanilla consensus-v32 wasm module root
 *
 *          Mirrors CelestiaNitroContracts2Point1Point3UpgradeAction in reverse. The OSP currently
 *          installed on the ChallengeManager (the celestia OSP) is read live at execution time and
 *          kept as condOsp. perform() requires the chain to currently be on the celestia root, so
 *          it is intended for a chain still fully on Celestia.
 *
 *          Will revert if the bridge is an ERC20Bridge below v2.x.x.
 */
contract VanillaMigrationNitroContracts2Point1Point3UpgradeAction {
  // OSP / ChallengeManager / wasm root migration requirements
  bytes32 public immutable newWasmModuleRoot;
  IOneStepProofEntry public immutable osp;
  bytes32 public immutable condRoot;
  address public immutable newChallengeManagerImpl;
  // 2.1.3 inbox / sequencer inbox implementations
  address public immutable newEthInboxImpl;
  address public immutable newERC20InboxImpl;
  address public immutable newEthSequencerInboxImpl;
  address public immutable newERC20SequencerInboxImpl;

  constructor(
    address _newEthInboxImpl,
    address _newERC20InboxImpl,
    address _newEthSequencerInboxImpl,
    address _newERC20SequencerInboxImpl,
    bytes32 _newWasmModuleRoot,
    address _newChallengeManagerImpl,
    IOneStepProofEntry _osp,
    bytes32 _condRoot
  ) {
    require(
      Address.isContract(_newEthInboxImpl),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: _newEthInboxImpl is not a contract'
    );
    require(
      Address.isContract(_newERC20InboxImpl),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: _newERC20InboxImpl is not a contract'
    );
    require(
      Address.isContract(_newEthSequencerInboxImpl),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: _newEthSequencerInboxImpl is not a contract'
    );
    require(
      Address.isContract(_newERC20SequencerInboxImpl),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: _newERC20SequencerInboxImpl is not a contract'
    );
    require(
      _newWasmModuleRoot != bytes32(0),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: _newWasmModuleRoot is empty'
    );
    require(
      Address.isContract(_newChallengeManagerImpl),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: _newChallengeManagerImpl is not a contract'
    );
    require(
      Address.isContract(address(_osp)),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: _osp is not a contract'
    );
    require(
      _condRoot != bytes32(0),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: _condRoot is empty'
    );

    newEthInboxImpl = _newEthInboxImpl;
    newERC20InboxImpl = _newERC20InboxImpl;
    newEthSequencerInboxImpl = _newEthSequencerInboxImpl;
    newERC20SequencerInboxImpl = _newERC20SequencerInboxImpl;

    newWasmModuleRoot = _newWasmModuleRoot;
    newChallengeManagerImpl = _newChallengeManagerImpl;
    osp = _osp;
    condRoot = _condRoot;
  }

  function perform(
    IRollupCore rollup,
    address inbox,
    ProxyAdmin proxyAdmin
  ) external {
    // make sure inbox is an inbox (and not the rollup, which also has bridge()/sequencerInbox())
    try IInbox(inbox).allowListEnabled() returns (bool) {} catch {
      revert(
        'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: inbox is not an inbox'
      );
    }

    // require the chain to currently be on the celestia root (still fully on Celestia)
    require(
      rollup.wasmModuleRoot() == condRoot,
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: wasm root mismatch'
    );

    address bridge = IInbox(inbox).bridge();
    address sequencerInbox = IInbox(inbox).sequencerInbox();

    bool isERC20 = false;

    // if the bridge is an ERC20Bridge below v2.x.x, revert
    try IERC20Bridge(bridge).nativeToken() returns (address) {
      isERC20 = true;
      // it is an ERC20Bridge, check if it is on v2.x.x
      try IERC20Bridge_v2(address(bridge)).nativeTokenDecimals() returns (
        uint8
      ) {} catch {
        revert(
          'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: bridge is an ERC20Bridge below v2.x.x'
        );
      }
    } catch {}

    // upgrade the sequencer inbox to vanilla 2.1.3
    proxyAdmin.upgrade({
      proxy: TransparentUpgradeableProxy(payable((sequencerInbox))),
      implementation: isERC20
        ? newERC20SequencerInboxImpl
        : newEthSequencerInboxImpl
    });

    // upgrade the inbox to vanilla 2.1.3
    proxyAdmin.upgrade({
      proxy: TransparentUpgradeableProxy(payable((inbox))),
      implementation: isERC20 ? newERC20InboxImpl : newEthInboxImpl
    });

    // migrate the osp back to vanilla
    TransparentUpgradeableProxy challengeManager = TransparentUpgradeableProxy(
      payable(address(rollup.challengeManager()))
    );

    // read the OSP currently installed (the celestia OSP) so any in-flight challenge anchored at
    // the celestia root keeps being adjudicated by it
    IOneStepProofEntry condOsp = IOneStepProofEntry(
      IChallengeManagerUpgradeInit(address(challengeManager)).osp()
    );
    require(
      address(condOsp) != address(osp),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: OSP already vanilla'
    );
require(
  IChallengeManagerUpgradeInit(address(challengeManager)).getOsp(newWasmModuleRoot) == address(osp),
  "VanillaMigrationNitroContracts2Point1Point3UpgradeAction: target root OSP mismatch"
);
    proxyAdmin.upgradeAndCall(
      challengeManager,
      newChallengeManagerImpl,
      abi.encodeCall(
        IChallengeManagerUpgradeInit.postUpgradeInit,
        (osp, condRoot, condOsp)
      )
    );

    // verify
    require(
      proxyAdmin.getProxyImplementation(challengeManager) ==
        newChallengeManagerImpl,
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: new challenge manager implementation set'
    );
    require(
      IChallengeManagerUpgradeInit(address(challengeManager)).osp() ==
        address(osp),
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: new OSP not set'
    );

    // set new (vanilla) wasm module root
    IRollupAdmin(address(rollup)).setWasmModuleRoot(newWasmModuleRoot);

    // verify
    require(
      rollup.wasmModuleRoot() == newWasmModuleRoot,
      'VanillaMigrationNitroContracts2Point1Point3UpgradeAction: wasm module root not set'
    );
  }
}
