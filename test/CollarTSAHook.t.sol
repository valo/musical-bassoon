// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Test} from "forge-std/Test.sol";

import {CollarTSAHook, ICollarTSA, MatchingAction} from "../src/CollarTSAHook.sol";
import {DstPostHookCallParams, DstPreHookCallParams, SrcPostHookCallParams, SrcPreHookCallParams, TransferInfo} from "../lib/socket-plugs/contracts/common/Structs.sol";
import {ERC20} from "../lib/socket-plugs/lib/solmate/src/tokens/ERC20.sol";

contract MockBridgeToken {
  address public token;

  constructor(address token_) {
    token = token_;
  }
}

contract MockToken is ERC20 {
  constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_, decimals_) {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

contract MockCollarTSA is ICollarTSA {
  CollarTSAParams private params;
  address private wrappedAsset;
  address private depositModule;
  uint256 private subaccountId;

  MatchingAction public lastAction;
  bool public signCalled;
  bool public shouldRevert;

  constructor(address wrappedAsset_, address depositModule_, uint256 subaccountId_, uint256 minExpiry) {
    wrappedAsset = wrappedAsset_;
    depositModule = depositModule_;
    subaccountId = subaccountId_;
    params = CollarTSAParams({
      minSignatureExpiry: minExpiry,
      maxSignatureExpiry: minExpiry + 1 hours,
      optionVolSlippageFactor: 0,
      callMaxDelta: 0,
      maxNegCash: 0,
      optionMinTimeToExpiry: 0,
      optionMaxTimeToExpiry: 0,
      putMaxPriceFactor: 0
    });
  }

  function setShouldRevert(bool value) external {
    shouldRevert = value;
  }

  function signActionData(MatchingAction memory action, bytes memory) external override {
    if (shouldRevert) {
      revert("mock revert");
    }
    signCalled = true;
    lastAction = action;
  }

  function getLastAction() external view returns (MatchingAction memory) {
    return lastAction;
  }

  function getCollarTSAParams() external view override returns (CollarTSAParams memory) {
    return params;
  }

  function getCollarTSAAddresses()
    external
    view
    override
    returns (address, address, address, address, address, address)
  {
    return (address(0), depositModule, address(0), address(0), address(0), address(0));
  }

  function getBaseTSAAddresses()
    external
    view
    override
    returns (address, address, address, address, address, address, address)
  {
    return (address(0), address(0), wrappedAsset, address(0), address(0), address(0), address(0));
  }

  function subAccount() external view override returns (uint256) {
    return subaccountId;
  }
}

contract CollarTSAHookTest is Test {
  MockToken internal token;
  MockBridgeToken internal bridge;
  MockCollarTSA internal tsa;
  CollarTSAHook internal hook;

  address internal fallbackRecipient = address(0xBEEF);
  address internal recipient = address(0xCAFE);

  uint256 internal constant LOAN_ID = 42;
  uint256 internal constant SUBACCOUNT_ID = 7;
  uint256 internal constant MIN_EXPIRY = 60;

  function setUp() public {
    token = new MockToken("Token", "TOK", 18);
    bridge = new MockBridgeToken(address(token));
    tsa = new MockCollarTSA(address(token), address(0x1234), SUBACCOUNT_ID, MIN_EXPIRY);
    hook = new CollarTSAHook(address(this), address(bridge), fallbackRecipient, address(tsa));
  }

  function testDstPreHookIntercepts() public {
    bytes memory payload =
      abi.encode(CollarTSAHook.ActionType.DepositCollateral, LOAN_ID, address(token), 1e18, recipient, SUBACCOUNT_ID);
    TransferInfo memory info = TransferInfo({receiver: recipient, amount: 1e18, extraData: payload});
    DstPreHookCallParams memory params = DstPreHookCallParams({connector: address(0), connectorCache: bytes(""), transferInfo: info});

    vm.prank(address(bridge));
    (bytes memory postHookData, TransferInfo memory updated) = hook.dstPreHookCall(params);

    assertEq(updated.receiver, address(hook));
    assertEq(postHookData, payload);
  }

  function testDstPostHookDepositSuccess() public {
    uint256 amount = 5e18;
    bytes32 messageId = bytes32(uint256(123));

    bytes memory payload =
      abi.encode(CollarTSAHook.ActionType.DepositCollateral, LOAN_ID, address(token), amount, recipient, SUBACCOUNT_ID);
    TransferInfo memory info = TransferInfo({receiver: recipient, amount: amount, extraData: bytes("")});
    DstPostHookCallParams memory params = DstPostHookCallParams({
      connector: address(0),
      messageId: messageId,
      connectorCache: bytes(""),
      postHookData: payload,
      transferInfo: info
    });

    token.mint(address(hook), amount);

    vm.prank(address(bridge));
    hook.dstPostHookCall(params);

    assertEq(token.balanceOf(address(tsa)), amount);
    assertTrue(tsa.signCalled());

    MatchingAction memory action = tsa.getLastAction();
    assertEq(action.subaccountId, SUBACCOUNT_ID);
    assertEq(action.owner, address(tsa));
    assertEq(action.signer, address(tsa));
    assertEq(uint256(action.nonce), uint256(messageId));
    assertEq(action.expiry, block.timestamp + MIN_EXPIRY);
    assertEq(address(action.module), address(0x1234));

    assertEq(uint256(hook.loanStatus(LOAN_ID, uint8(CollarTSAHook.ActionType.DepositCollateral))), uint256(CollarTSAHook.Status.Received));
  }

  function testDstPostHookDepositFailureFallsBack() public {
    uint256 amount = 3e18;
    bytes32 messageId = bytes32(uint256(456));

    bytes memory payload =
      abi.encode(CollarTSAHook.ActionType.DepositCollateral, LOAN_ID, address(token), amount, recipient, SUBACCOUNT_ID);
    TransferInfo memory info = TransferInfo({receiver: recipient, amount: amount, extraData: bytes("")});
    DstPostHookCallParams memory params = DstPostHookCallParams({
      connector: address(0),
      messageId: messageId,
      connectorCache: bytes(""),
      postHookData: payload,
      transferInfo: info
    });

    token.mint(address(hook), amount);
    tsa.setShouldRevert(true);

    vm.prank(address(bridge));
    hook.dstPostHookCall(params);

    assertEq(token.balanceOf(address(tsa)), amount);
    assertEq(uint256(hook.loanStatus(LOAN_ID, uint8(CollarTSAHook.ActionType.DepositCollateral))), uint256(CollarTSAHook.Status.Failed));
  }

  function testDstPostHookTransferSuccess() public {
    uint256 amount = 2e18;
    bytes32 messageId = bytes32(uint256(789));

    bytes memory payload =
      abi.encode(CollarTSAHook.ActionType.SettleUSDC, LOAN_ID, address(token), amount, recipient, SUBACCOUNT_ID);
    TransferInfo memory info = TransferInfo({receiver: recipient, amount: amount, extraData: bytes("")});
    DstPostHookCallParams memory params = DstPostHookCallParams({
      connector: address(0),
      messageId: messageId,
      connectorCache: bytes(""),
      postHookData: payload,
      transferInfo: info
    });

    token.mint(address(hook), amount);

    vm.prank(address(bridge));
    hook.dstPostHookCall(params);

    assertEq(token.balanceOf(recipient), amount);
    assertEq(uint256(hook.loanStatus(LOAN_ID, uint8(CollarTSAHook.ActionType.SettleUSDC))), uint256(CollarTSAHook.Status.Received));
  }

  function testSrcPostHookSetsSent() public {
    bytes memory payload =
      abi.encode(CollarTSAHook.ActionType.ReturnCollateral, LOAN_ID, address(token), 1e18, recipient, SUBACCOUNT_ID);
    TransferInfo memory info = TransferInfo({receiver: recipient, amount: 1e18, extraData: payload});
    SrcPostHookCallParams memory params = SrcPostHookCallParams({
      connector: address(0),
      options: bytes(""),
      postHookData: payload,
      transferInfo: info
    });

    vm.prank(address(bridge));
    hook.srcPostHookCall(params);

    assertEq(uint256(hook.loanStatus(LOAN_ID, uint8(CollarTSAHook.ActionType.ReturnCollateral))), uint256(CollarTSAHook.Status.Sent));
  }
}
