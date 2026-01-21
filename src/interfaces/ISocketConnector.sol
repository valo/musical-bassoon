// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISocketConnector {
  function getMinFees(uint256 msgGasLimit_, uint256 payloadSize_) external view returns (uint256 totalFees);
  function getMessageId() external view returns (bytes32);
}
