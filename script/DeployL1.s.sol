// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {CollarVault} from "../src/CollarVault.sol";
import {CollarVaultMessenger} from "../src/bridge/CollarVaultMessenger.sol";

/// @dev Deploy L1 components against a fork (mainnet).
///
/// Required env vars:
/// - ADMIN (address)
/// - BRIDGE_CONFIG_ADMIN (address)
/// - LIQUIDITY_VAULT (address)
/// - EULER_ADAPTER (address)
/// - PERMIT2 (address)
/// - TREASURY (address)
/// - L2_RECIPIENT (address)           (address on OP that receives bridged collateral)
/// - LZ_ENDPOINT (address)            (LayerZero endpoint on L1)
/// - L2_EID (uint32)                  (LayerZero destination endpoint id)
/// - OUTPUT_JSON (string)             (path to write a small addresses json)
///
/// Optional:
/// - VAULT_OWNER (address)            (defaults to ADMIN)
contract DeployL1 is Script {
  function run() external {
    address admin = vm.envAddress("ADMIN");
    address bridgeConfigAdmin = vm.envAddress("BRIDGE_CONFIG_ADMIN");
    address liquidityVault = vm.envAddress("LIQUIDITY_VAULT");
    address eulerAdapter = vm.envAddress("EULER_ADAPTER");
    address permit2 = vm.envAddress("PERMIT2");
    address treasury = vm.envAddress("TREASURY");
    address l2Recipient = vm.envAddress("L2_RECIPIENT");

    address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
    uint32 l2Eid = uint32(vm.envUint("L2_EID"));

    address vaultOwner = vm.envOr("VAULT_OWNER", admin);

    vm.startBroadcast();

    CollarVault vault = new CollarVault(
      vaultOwner,
      CollarVault.ILiquidityVault(liquidityVault),
      bridgeConfigAdmin,
      CollarVault.IEulerAdapter(eulerAdapter),
      CollarVault.IAllowanceTransfer(permit2),
      l2Recipient,
      treasury
    );

    CollarVaultMessenger messenger = new CollarVaultMessenger(admin, address(vault), lzEndpoint, l2Eid);

    // Wire the messenger into the vault
    vault.setLZMessenger(CollarVault.ICollarVaultMessenger(address(messenger)));

    vm.stopBroadcast();

    string memory outPath = vm.envString("OUTPUT_JSON");

    string memory json;
    json = vm.serializeAddress("addrs", "l1Vault", address(vault));
    json = vm.serializeAddress("addrs", "l1Messenger", address(messenger));
    vm.writeJson(json, outPath);

    console2.log("L1 vault", address(vault));
    console2.log("L1 messenger", address(messenger));
    console2.log("Wrote", outPath);
  }
}
