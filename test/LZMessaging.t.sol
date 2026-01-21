// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MessagingParams, MessagingFee, MessagingReceipt, Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IActionVerifier} from "v2-matching/src/interfaces/IActionVerifier.sol";

import {CollarVaultMessenger} from "../src/bridge/CollarVaultMessenger.sol";
import {CollarTSAReceiver} from "../src/bridge/CollarTSAReceiver.sol";
import {CollarLZMessages} from "../src/bridge/CollarLZMessages.sol";
import {ISocketMessageTracker} from "../src/interfaces/ISocketMessageTracker.sol";
import {ICollarTSA} from "../src/interfaces/ICollarTSA.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockEndpointV2 {
  uint64 public nonce;
  uint256 public quoteFee = 1;
  address public delegate;

  uint32 public lastDstEid;
  bytes32 public lastReceiver;
  bytes public lastMessage;
  bytes public lastOptions;
  bool public lastPayInLzToken;
  uint256 public lastNativeFee;
  uint256 public lastLzTokenFee;
  bytes32 public lastGuid;
  address public lastRefundAddress;

  function setQuoteFee(uint256 fee) external {
    quoteFee = fee;
  }

  function setDelegate(address delegate_) external {
    delegate = delegate_;
  }

  function lzToken() external pure returns (address) {
    return address(0);
  }

  function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
    return MessagingFee({nativeFee: quoteFee, lzTokenFee: 0});
  }

  function send(MessagingParams calldata params, address refundAddress) external payable returns (MessagingReceipt memory) {
    nonce++;
    lastDstEid = params.dstEid;
    lastReceiver = params.receiver;
    lastMessage = params.message;
    lastOptions = params.options;
    lastPayInLzToken = params.payInLzToken;
    lastNativeFee = msg.value;
    lastLzTokenFee = 0;
    lastRefundAddress = refundAddress;
    lastGuid = keccak256(abi.encodePacked(nonce, params.dstEid, params.receiver, params.message));

    return MessagingReceipt({guid: lastGuid, nonce: nonce, fee: MessagingFee(msg.value, 0)});
  }
}

contract MockSocketMessageTracker is ISocketMessageTracker {
  mapping(bytes32 => bool) public executed;

  function setExecuted(bytes32 messageId, bool value) external {
    executed[messageId] = value;
  }

  function messageExecuted(bytes32 messageId) external view returns (bool) {
    return executed[messageId];
  }
}

contract MockRfqModule {
  mapping(address => mapping(uint256 => bool)) public usedNonces;

  function setUsedNonce(address owner, uint256 nonce, bool value) external {
    usedNonces[owner][nonce] = value;
  }
}

contract MockCollarTSA is ICollarTSA {
  IActionVerifier.Action public lastAction;
  address public depositModule;
  address public withdrawalModule;
  address public rfqModule;
  address public wrappedDepositAsset;
  uint256 public subaccountId;
  CollarTSAParams private params;

  constructor(address wrappedDepositAsset_, address rfqModule_) {
    depositModule = address(0x1234);
    withdrawalModule = address(0x5678);
    rfqModule = rfqModule_;
    wrappedDepositAsset = wrappedDepositAsset_;
    subaccountId = 1;
    params.minSignatureExpiry = 1 minutes;
    params.maxSignatureExpiry = 30 minutes;
  }

  function signActionData(IActionVerifier.Action memory action, bytes memory) external {
    lastAction = action;
  }

  function getLastAction() external view returns (IActionVerifier.Action memory) {
    return lastAction;
  }

  function getCollarTSAParams() external view returns (CollarTSAParams memory) {
    return params;
  }

  function getCollarTSAAddresses()
    external
    view
    returns (address, address, address, address, address, address)
  {
    return (address(0), depositModule, withdrawalModule, address(0), rfqModule, address(0));
  }

  function getBaseTSAAddresses()
    external
    view
    returns (address, address, address, address, address, address, address)
  {
    return (address(0), address(0), wrappedDepositAsset, address(0), address(0), address(0), address(0));
  }

  function subAccount() external view returns (uint256) {
    return subaccountId;
  }
}

contract LZMessagingTest is Test {
  CollarVaultMessenger internal messenger;
  CollarTSAReceiver internal receiver;
  MockSocketMessageTracker internal socket;
  MockCollarTSA internal tsa;
  MockRfqModule internal rfqModule;
  MockERC20 internal token;
  MockEndpointV2 internal endpointL1;
  MockEndpointV2 internal endpointL2;
  address internal vaultRecipient;

  uint32 internal constant L1_EID = 1;
  uint32 internal constant L2_EID = 2;

  function setUp() public {
    endpointL1 = new MockEndpointV2();
    endpointL2 = new MockEndpointV2();

    token = new MockERC20("Mock", "MOCK", 18);
    socket = new MockSocketMessageTracker();
    rfqModule = new MockRfqModule();
    tsa = new MockCollarTSA(address(token), address(rfqModule));

    messenger = new CollarVaultMessenger(address(this), address(this), address(endpointL1), L2_EID);
    receiver = new CollarTSAReceiver(address(this), address(endpointL2), socket, tsa, L1_EID);
    vaultRecipient = address(0xCAFE);
    receiver.setVaultRecipient(vaultRecipient);

    messenger.setPeer(L2_EID, _addressToBytes32(address(receiver)));
    receiver.setPeer(L1_EID, _addressToBytes32(address(messenger)));
  }

  function testQuoteMessageReturnsFee() public {
    endpointL1.setQuoteFee(42);

    CollarLZMessages.Message memory message = _buildMessage(CollarLZMessages.Action.DepositIntent, bytes32(0));
    MessagingFee memory fee = messenger.quoteMessage(message, "");

    assertEq(fee.nativeFee, 42);
    assertEq(fee.lzTokenFee, 0);
  }

  function testL1ToL2MessageStored() public {
    CollarLZMessages.Message memory message = _buildMessage(CollarLZMessages.Action.DepositIntent, bytes32(0));

    MessagingReceipt memory receipt = messenger.sendMessageWithOptions{value: 1}(message, "");

    assertEq(endpointL1.lastDstEid(), L2_EID);
    assertEq(endpointL1.lastReceiver(), _addressToBytes32(address(receiver)));

    _deliverToReceiver(receipt.guid, message);

    (CollarLZMessages.Action action, uint256 loanId,, , , , , , ,) = receiver.pendingMessages(receipt.guid);
    assertEq(loanId, message.loanId);
    assertEq(uint8(action), uint8(message.action));
  }

  function testHandleDepositSendsAck() public {
    bytes32 socketMessageId = bytes32(uint256(100));
    CollarLZMessages.Message memory message = _buildMessage(CollarLZMessages.Action.DepositIntent, socketMessageId);

    socket.setExecuted(socketMessageId, true);
    token.mint(address(receiver), message.amount);

    MessagingReceipt memory receipt = messenger.sendMessageWithOptions{value: 1}(message, "");
    _deliverToReceiver(receipt.guid, message);

    receiver.handleMessage(receipt.guid);

    assertTrue(receiver.handledMessages(receipt.guid));

    IActionVerifier.Action memory action = tsa.getLastAction();
    assertEq(address(action.module), tsa.depositModule());
    assertEq(action.subaccountId, message.subaccountId);
    assertEq(action.nonce, uint256(message.socketMessageId));

    CollarLZMessages.Message memory ackMessage =
      abi.decode(endpointL2.lastMessage(), (CollarLZMessages.Message));
    assertEq(endpointL2.lastDstEid(), L1_EID);
    assertEq(uint8(ackMessage.action), uint8(CollarLZMessages.Action.DepositConfirmed));
    assertEq(ackMessage.loanId, message.loanId);
    assertEq(ackMessage.asset, message.asset);
    assertEq(ackMessage.amount, message.amount);
    assertEq(ackMessage.recipient, message.recipient);

    _deliverToMessenger(endpointL2.lastGuid(), ackMessage);

    (CollarLZMessages.Action storedAction, uint256 storedLoanId,, , , , , , ,) =
      messenger.receivedMessages(endpointL2.lastGuid());
    assertEq(storedLoanId, message.loanId);
    assertEq(uint8(storedAction), uint8(CollarLZMessages.Action.DepositConfirmed));
  }

  function testHandleMessageRevertsIfSocketPending() public {
    bytes32 socketMessageId = bytes32(uint256(200));
    CollarLZMessages.Message memory message = _buildMessage(CollarLZMessages.Action.DepositIntent, socketMessageId);

    MessagingReceipt memory receipt = messenger.sendMessageWithOptions{value: 1}(message, "");
    _deliverToReceiver(receipt.guid, message);

    vm.expectRevert(CollarTSAReceiver.CTR_SocketNotFinalized.selector);
    receiver.handleMessage(receipt.guid);
  }

  function testHandleCancelRequestSignsWithdrawalWithGuidNonce() public {
    CollarLZMessages.Message memory message = _buildMessage(CollarLZMessages.Action.CancelRequest, bytes32(0));

    MessagingReceipt memory receipt = messenger.sendMessageWithOptions{value: 1}(message, "");
    _deliverToReceiver(receipt.guid, message);

    receiver.handleMessage(receipt.guid);

    IActionVerifier.Action memory action = tsa.getLastAction();
    assertEq(address(action.module), tsa.withdrawalModule());
    assertEq(action.subaccountId, message.subaccountId);
    assertEq(action.nonce, uint256(receipt.guid));
  }

  function testSendTradeConfirmedRequiresUsedNonce() public {
    bytes32 quoteHash = keccak256("quote");
    uint256 takerNonce = 42;

    vm.expectRevert(CollarTSAReceiver.CTR_RfqTradeNotConfirmed.selector);
    receiver.sendTradeConfirmed{value: 1}(1, quoteHash, takerNonce);
  }

  function testSendTradeConfirmedStoresOnL1() public {
    bytes32 quoteHash = keccak256("quote");
    uint256 takerNonce = 42;

    rfqModule.setUsedNonce(address(tsa), takerNonce, true);

    receiver.sendTradeConfirmed{value: 1}(1, quoteHash, takerNonce);

    CollarLZMessages.Message memory tradeMessage =
      abi.decode(endpointL2.lastMessage(), (CollarLZMessages.Message));
    assertEq(uint8(tradeMessage.action), uint8(CollarLZMessages.Action.TradeConfirmed));
    assertEq(tradeMessage.loanId, 1);
    assertEq(tradeMessage.recipient, vaultRecipient);
    assertEq(tradeMessage.quoteHash, quoteHash);
    assertEq(tradeMessage.takerNonce, takerNonce);

    _deliverToMessenger(endpointL2.lastGuid(), tradeMessage);

    (, uint256 storedLoanId,, , , , , , bytes32 storedQuoteHash, uint256 storedTakerNonce) =
      messenger.receivedMessages(endpointL2.lastGuid());
    assertEq(storedLoanId, 1);
    assertEq(storedQuoteHash, quoteHash);
    assertEq(storedTakerNonce, takerNonce);
  }

  function testSendCollateralReturnedStoresOnL1() public {
    bytes32 socketMessageId = bytes32(uint256(300));

    receiver.sendCollateralReturned{value: 1}(1, address(token), 2e18, socketMessageId);

    CollarLZMessages.Message memory returnedMessage =
      abi.decode(endpointL2.lastMessage(), (CollarLZMessages.Message));
    assertEq(uint8(returnedMessage.action), uint8(CollarLZMessages.Action.CollateralReturned));
    assertEq(returnedMessage.loanId, 1);
    assertEq(returnedMessage.asset, address(token));
    assertEq(returnedMessage.amount, 2e18);
    assertEq(returnedMessage.socketMessageId, socketMessageId);
    assertEq(returnedMessage.recipient, vaultRecipient);

    _deliverToMessenger(endpointL2.lastGuid(), returnedMessage);

    (CollarLZMessages.Action storedAction, uint256 storedLoanId,, , , , bytes32 storedSocketMessageId,, ,) =
      messenger.receivedMessages(endpointL2.lastGuid());
    assertEq(uint8(storedAction), uint8(CollarLZMessages.Action.CollateralReturned));
    assertEq(storedLoanId, 1);
    assertEq(storedSocketMessageId, socketMessageId);
  }

  function _buildMessage(CollarLZMessages.Action action, bytes32 socketMessageId)
    internal
    view
    returns (CollarLZMessages.Message memory)
  {
    return CollarLZMessages.Message({
      action: action,
      loanId: 1,
      asset: address(token),
      amount: 1e18,
      recipient: address(this),
      subaccountId: tsa.subAccount(),
      socketMessageId: socketMessageId,
      secondaryAmount: 0,
      quoteHash: bytes32(0),
      takerNonce: 0
    });
  }

  function _deliverToReceiver(bytes32 guid, CollarLZMessages.Message memory message) internal {
    Origin memory origin = Origin({
      srcEid: L1_EID,
      sender: _addressToBytes32(address(messenger)),
      nonce: 1
    });

    vm.prank(address(endpointL2));
    receiver.lzReceive(origin, guid, abi.encode(message), address(0), bytes(""));
  }

  function _deliverToMessenger(bytes32 guid, CollarLZMessages.Message memory message) internal {
    Origin memory origin = Origin({
      srcEid: L2_EID,
      sender: _addressToBytes32(address(receiver)),
      nonce: 1
    });

    vm.prank(address(endpointL1));
    messenger.lzReceive(origin, guid, abi.encode(message), address(0), bytes(""));
  }

  function _addressToBytes32(address value) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(value)));
  }
}
