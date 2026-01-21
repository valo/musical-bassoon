// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CollarLZMessages} from "../bridge/CollarLZMessages.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

interface ICollarVaultMessenger {
  function defaultOptions() external view returns (bytes memory);

  function quoteMessage(CollarLZMessages.Message calldata message, bytes calldata options)
    external
    view
    returns (MessagingFee memory fee);

  function sendMessage(CollarLZMessages.Message calldata message)
    external
    payable
    returns (MessagingReceipt memory receipt);

  function receivedMessages(bytes32 guid)
    external
    view
    returns (
      CollarLZMessages.Action action,
      uint256 loanId,
      address asset,
      uint256 amount,
      address recipient,
      uint256 subaccountId,
      bytes32 socketMessageId,
      uint256 secondaryAmount,
      bytes32 quoteHash,
      uint256 takerNonce
    );
}
