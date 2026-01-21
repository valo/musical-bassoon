// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library CollarLZMessages {
  enum Action {
    DepositIntent,
    CancelRequest,
    ReturnRequest,
    SettlementReport,
    DepositConfirmed,
    CollateralReturned
  }

  struct Message {
    Action action;
    uint256 loanId;
    address asset;
    uint256 amount;
    address recipient;
    uint256 subaccountId;
    bytes32 socketMessageId;
    uint256 secondaryAmount;
  }
}
