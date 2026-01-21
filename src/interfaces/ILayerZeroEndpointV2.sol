// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILayerZeroEndpointV2 {
  function send(uint32 dstEid, bytes32 receiver, bytes calldata message, bytes calldata options)
    external
    payable
    returns (bytes32 guid);
}
