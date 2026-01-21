// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISocketConnector} from "../../src/interfaces/ISocketConnector.sol";

contract MockConnector is ISocketConnector {
  uint256 public fee;
  bytes32 public messageId;

  constructor(uint256 fee_) {
    fee = fee_;
    messageId = bytes32(uint256(1));
  }

  function setFee(uint256 fee_) external {
    fee = fee_;
  }

  function setMessageId(bytes32 messageId_) external {
    messageId = messageId_;
  }

  function getMinFees(uint256, uint256) external view override returns (uint256 totalFees) {
    return fee;
  }

  function getMessageId() external view override returns (bytes32) {
    return messageId;
  }
}
