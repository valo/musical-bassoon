// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISocketConnector} from "../../src/interfaces/ISocketConnector.sol";

contract MockConnector is ISocketConnector {
  uint256 public fee;

  constructor(uint256 fee_) {
    fee = fee_;
  }

  function setFee(uint256 fee_) external {
    fee = fee_;
  }

  function getMinFees(uint256, uint256) external view override returns (uint256 totalFees) {
    return fee;
  }
}
