// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {CollarTSAReceiver} from "../src/bridge/CollarTSAReceiver.sol";

/// @dev Deploy L2 components against a fork (Optimism).
///
/// Required env vars:
/// - ADMIN (address)
/// - LZ_ENDPOINT (address)            (LayerZero endpoint on L2)
/// - SOCKET_TRACKER (address)         (ISocketMessageTracker)
/// - TSA (address)                    (ICollarTSA)
/// - L1_EID (uint32)                  (LayerZero destination endpoint id on L1)
/// - L1_MESSENGER (address)           (for setPeer)
/// - L1_VAULT (address)               (vaultRecipient)
/// - OUTPUT_JSON (string)
contract DeployL2 is Script {
  function run() external {
    address admin = vm.envAddress("ADMIN");
    address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
    address socketTracker = vm.envAddress("SOCKET_TRACKER");
    address tsa = vm.envAddress("TSA");
    uint32 l1Eid = uint32(vm.envUint("L1_EID"));

    address l1Messenger = vm.envAddress("L1_MESSENGER");
    address l1Vault = vm.envAddress("L1_VAULT");

    vm.startBroadcast();

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
    vm.writeJson(json, outPath);

    console2.log("L2 receiver", address(receiver));
    console2.log("Wrote", outPath);
  }
}
