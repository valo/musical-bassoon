// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {CollarTSAReceiver} from "../src/bridge/CollarTSAReceiver.sol";
import {SocketMessageTrackerMock} from "../src/mocks/SocketMessageTrackerMock.sol";
import {CollarTSAMock} from "../src/mocks/CollarTSAMock.sol";
import {LZEndpointV2Mock} from "../src/mocks/LZEndpointV2Mock.sol";

/// @dev Deploy L2 components against a fork (Optimism).
///
/// Required env vars:
/// - ADMIN (address)
/// - L1_MESSENGER (address)           (for setPeer)
/// - L1_VAULT (address)               (vaultRecipient)
/// - OUTPUT_JSON (string)
///
/// Optional:
/// - LZ_ENDPOINT (address)            (if omitted, deploys a placeholder mock endpoint)
/// - SOCKET_TRACKER (address)         (if omitted, deploys SocketMessageTrackerMock)
/// - TSA (address)                    (if omitted, deploys CollarTSAMock)
/// - TSA_SUBACCOUNT (uint256)         (default: 1)
/// - L1_EID (uint32)                  (default: 0)
contract DeployL2 is Script {
  function run() external {
    address admin = vm.envAddress("ADMIN");

    address l1Messenger = vm.envAddress("L1_MESSENGER");
    address l1Vault = vm.envAddress("L1_VAULT");

    address lzEndpoint = vm.envOr("LZ_ENDPOINT", address(0));
    address socketTracker = vm.envOr("SOCKET_TRACKER", address(0));
    address tsa = vm.envOr("TSA", address(0));

    uint256 tsaSubaccount = vm.envOr("TSA_SUBACCOUNT", uint256(1));
    uint32 l1Eid = uint32(vm.envOr("L1_EID", uint256(0)));

    vm.startBroadcast();

    if (lzEndpoint == address(0)) {
      lzEndpoint = address(new LZEndpointV2Mock());
    }

    if (socketTracker == address(0)) {
      socketTracker = address(new SocketMessageTrackerMock());
    }

    if (tsa == address(0)) {
      tsa = address(new CollarTSAMock(tsaSubaccount));
    }

    CollarTSAReceiver receiver = new CollarTSAReceiver(
      admin,
      lzEndpoint,
      CollarTSAReceiver.ISocketMessageTracker(socketTracker),
      CollarTSAReceiver.ICollarTSA(tsa),
      l1Eid
    );

    receiver.setVaultRecipient(l1Vault);
    // Allow messages from the L1 messenger
    receiver.setPeer(l1Eid, bytes32(uint256(uint160(l1Messenger))));

    vm.stopBroadcast();

    string memory outPath = vm.envString("OUTPUT_JSON");

    string memory json;
    json = vm.serializeAddress("addrs", "l2Receiver", address(receiver));
    json = vm.serializeAddress("addrs", "l2SocketTracker", socketTracker);
    json = vm.serializeAddress("addrs", "l2Tsa", tsa);
    json = vm.serializeAddress("addrs", "l2LzEndpoint", lzEndpoint);
    vm.writeJson(json, outPath);

    console2.log("L2 receiver", address(receiver));
    console2.log("L2 socketTracker", socketTracker);
    console2.log("L2 tsa", tsa);
    console2.log("L2 lzEndpoint", lzEndpoint);
    console2.log("Wrote", outPath);
  }
}
