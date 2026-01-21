// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {HookBase} from "../lib/socket-plugs/contracts/hooks/HookBase.sol";
import {CacheData, DstPostHookCallParams, DstPreHookCallParams, PostRetryHookCallParams, PreRetryHookCallParams, SrcPostHookCallParams, SrcPreHookCallParams, TransferInfo} from "../lib/socket-plugs/contracts/common/Structs.sol";
import {ERC20} from "../lib/socket-plugs/lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "../lib/socket-plugs/lib/solmate/src/utils/SafeTransferLib.sol";

interface IBridgeToken {
  function token() external view returns (address);
}

struct MatchingAction {
  uint256 subaccountId;
  uint256 nonce;
  address module;
  bytes data;
  uint256 expiry;
  address owner;
  address signer;
}

struct DepositData {
  uint256 amount;
  address asset;
  address managerForNewAccount;
}

interface ICollarTSA {
  struct CollarTSAParams {
    uint256 minSignatureExpiry;
    uint256 maxSignatureExpiry;
    uint256 optionVolSlippageFactor;
    uint256 callMaxDelta;
    int256 maxNegCash;
    uint256 optionMinTimeToExpiry;
    uint256 optionMaxTimeToExpiry;
    uint256 putMaxPriceFactor;
  }

  function signActionData(MatchingAction memory action, bytes memory extraData) external;
  function getCollarTSAParams() external view returns (CollarTSAParams memory);
  function getCollarTSAAddresses()
    external
    view
    returns (address, address, address, address, address, address);
  function getBaseTSAAddresses()
    external
    view
    returns (address, address, address, address, address, address, address);
  function subAccount() external view returns (uint256);
}

/// @notice Socket hook for Collar TSA flows.
contract CollarTSAHook is HookBase {
  using SafeTransferLib for ERC20;

  enum ActionType {
    DepositCollateral,
    RollCollateral,
    ReturnCollateral,
    CancelCollateral,
    SettleUSDC
  }

  enum Status {
    None,
    Sent,
    Received,
    Failed
  }

  struct CollarAction {
    ActionType actionType;
    uint256 loanId;
    address asset;
    uint256 amount;
    address recipient;
    uint256 subaccountId;
  }

  uint256 public constant ACTION_DATA_LENGTH = 32 * 6;

  address public tsa;
  address public fallbackRecipient;

  mapping(uint256 => mapping(uint8 => Status)) public loanStatus;
  event HookSent(uint256 indexed loanId, ActionType actionType, address asset, uint256 amount);
  event HookReceived(bytes32 indexed messageId, uint256 indexed loanId, ActionType actionType, bool success);
  event TSAUpdated(address indexed tsa);
  event FallbackRecipientUpdated(address indexed recipient);

  error CTH_InvalidExtraData();
  error CTH_InvalidRecipient();
  error CTH_RetryNotSupported();

  constructor(address owner_, address vaultOrController_, address fallbackRecipient_, address tsa_)
    HookBase(owner_, vaultOrController_)
  {
    if (fallbackRecipient_ == address(0)) {
      revert CTH_InvalidRecipient();
    }
    fallbackRecipient = fallbackRecipient_;
    tsa = tsa_;
  }

  function setTSA(address newTsa) external onlyOwner {
    tsa = newTsa;
    emit TSAUpdated(newTsa);
  }

  function setFallbackRecipient(address newRecipient) external onlyOwner {
    if (newRecipient == address(0)) {
      revert CTH_InvalidRecipient();
    }
    fallbackRecipient = newRecipient;
    emit FallbackRecipientUpdated(newRecipient);
  }

  function srcPreHookCall(SrcPreHookCallParams calldata params)
    external
    override
    isVaultOrController
    returns (TransferInfo memory transferInfo, bytes memory postHookData)
  {
    transferInfo = params.transferInfo;
    postHookData = params.transferInfo.extraData;
  }

  function srcPostHookCall(SrcPostHookCallParams calldata params)
    external
    override
    isVaultOrController
    returns (TransferInfo memory transferInfo)
  {
    transferInfo = params.transferInfo;

    if (params.postHookData.length == ACTION_DATA_LENGTH) {
      CollarAction memory action = _decodeAction(params.postHookData);
      _setStatus(action.loanId, action.actionType, Status.Sent);
      emit HookSent(action.loanId, action.actionType, action.asset, action.amount);
    }
  }

  function dstPreHookCall(DstPreHookCallParams calldata params)
    external
    override
    isVaultOrController
    returns (bytes memory postHookData, TransferInfo memory transferInfo)
  {
    transferInfo = params.transferInfo;
    if (params.transferInfo.extraData.length != ACTION_DATA_LENGTH) {
      return (bytes(""), transferInfo);
    }

    postHookData = params.transferInfo.extraData;
    transferInfo.receiver = address(this);
  }

  function dstPostHookCall(DstPostHookCallParams calldata params)
    external
    override
    isVaultOrController
    returns (CacheData memory cacheData)
  {
    if (params.postHookData.length != ACTION_DATA_LENGTH) {
      return CacheData(bytes(""), bytes(""));
    }

    CollarAction memory action = _decodeAction(params.postHookData);
    bool success = _handleInbound(action, params.messageId, params.transferInfo.amount);

    if (success) {
      _setStatus(action.loanId, action.actionType, Status.Received);
    } else {
      _setStatus(action.loanId, action.actionType, Status.Failed);
    }

    emit HookReceived(params.messageId, action.loanId, action.actionType, success);
    return CacheData(bytes(""), bytes(""));
  }

  function preRetryHook(PreRetryHookCallParams calldata)
    external
    pure
    override
    returns (bytes memory, TransferInfo memory)
  {
    revert CTH_RetryNotSupported();
  }

  function postRetryHook(PostRetryHookCallParams calldata)
    external
    pure
    override
    returns (CacheData memory)
  {
    revert CTH_RetryNotSupported();
  }

  function _handleInbound(CollarAction memory action, bytes32 messageId, uint256 transferAmount)
    internal
    returns (bool)
  {
    if (action.recipient == address(0)) {
      _sendToFallback(action.asset, transferAmount);
      return false;
    }

    if (action.amount == 0 || action.amount != transferAmount) {
      _sendToFallback(action.asset, transferAmount);
      return false;
    }

    address bridgeToken = IBridgeToken(vaultOrController).token();
    if (action.asset != bridgeToken) {
      _sendToFallback(action.asset, transferAmount);
      return false;
    }

    if (action.actionType == ActionType.DepositCollateral || action.actionType == ActionType.RollCollateral) {
      return _handleDeposit(action, messageId);
    }

    return _handleTransfer(action);
  }

  function _handleDeposit(CollarAction memory action, bytes32 messageId) internal returns (bool) {
    if (tsa == address(0)) {
      _sendToFallback(action.asset, action.amount);
      return false;
    }

    ICollarTSA tsaContract = ICollarTSA(tsa);
    if (action.subaccountId != tsaContract.subAccount()) {
      _sendToFallback(action.asset, action.amount);
      return false;
    }

    (
      ,
      address depositModule,
      ,
      ,
      ,
    ) = tsaContract.getCollarTSAAddresses();
    (, , address wrappedDepositAsset,, , ,) = tsaContract.getBaseTSAAddresses();
    ICollarTSA.CollarTSAParams memory params = tsaContract.getCollarTSAParams();

    ERC20(action.asset).safeTransfer(tsa, action.amount);

    DepositData memory depositData = DepositData({
      amount: action.amount,
      asset: wrappedDepositAsset,
      managerForNewAccount: address(0)
    });

    MatchingAction memory actionData = MatchingAction({
      subaccountId: action.subaccountId,
      nonce: uint256(messageId),
      module: depositModule,
      data: abi.encode(depositData),
      expiry: block.timestamp + params.minSignatureExpiry,
      owner: tsa,
      signer: tsa
    });

    try tsaContract.signActionData(actionData, bytes("")) {
      return true;
    } catch {
      return false;
    }
  }

  function _handleTransfer(CollarAction memory action) internal returns (bool) {
    ERC20(action.asset).safeTransfer(action.recipient, action.amount);
    return true;
  }

  function _sendToFallback(address asset, uint256 amount) internal {
    if (fallbackRecipient == address(0)) {
      revert CTH_InvalidRecipient();
    }
    ERC20(asset).safeTransfer(fallbackRecipient, amount);
  }

  function _decodeAction(bytes memory data) internal pure returns (CollarAction memory action) {
    if (data.length != ACTION_DATA_LENGTH) {
      revert CTH_InvalidExtraData();
    }

    (
      ActionType actionType,
      uint256 loanId,
      address asset,
      uint256 amount,
      address recipient,
      uint256 subaccountId
    ) = abi.decode(data, (ActionType, uint256, address, uint256, address, uint256));

    action = CollarAction({
      actionType: actionType,
      loanId: loanId,
      asset: asset,
      amount: amount,
      recipient: recipient,
      subaccountId: subaccountId
    });
  }

  function _setStatus(uint256 loanId, ActionType actionType, Status status) internal {
    loanStatus[loanId][uint8(actionType)] = status;
  }
}
