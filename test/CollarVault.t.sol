// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CollarLiquidityVault} from "../src/CollarLiquidityVault.sol";
import {CollarVault, ILiquidityVault} from "../src/CollarVault.sol";
import {IEulerAdapter} from "../src/interfaces/IEulerAdapter.sol";
import {ISocketBridge} from "../src/interfaces/ISocketBridge.sol";
import {ISocketConnector} from "../src/interfaces/ISocketConnector.sol";
import {ICollarVaultMessenger} from "../src/interfaces/ICollarVaultMessenger.sol";
import {CollarLZMessages} from "../src/bridge/CollarLZMessages.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {Permit2ECDSASigner} from "../lib/euler-earn/lib/euler-vault-kit/test/mocks/Permit2ECDSASigner.sol";

import {MockBridge} from "./mocks/MockBridge.sol";
import {MockConnector} from "./mocks/MockConnector.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockEulerAdapter} from "./mocks/MockEulerAdapter.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";

contract CollarVaultTest is Test {
  MockERC20 internal usdc;
  MockERC20 internal wbtc;
  CollarLiquidityVault internal liquidityVault;
  MockBridge internal bridge;
  MockConnector internal connector;
  MockEulerAdapter internal eulerAdapter;
  CollarVault internal vault;
  MockLZMessenger internal messenger;

  uint256 internal borrowerKey = 0xB0B0;
  address internal borrower;
  address internal treasury = address(0xB0B1);
  address internal keeper = address(0xA11CE);
  address internal executor = address(0xE1E1);
  address internal l2Recipient = address(0x1001);

  uint256 internal mmKey = 0xBEEF;
  address internal mmSigner;

  IAllowanceTransfer internal permit2;
  Permit2ECDSASigner internal permit2Signer;
  uint48 internal permitNonce;

  function setUp() public {
    usdc = new MockERC20("USD Coin", "USDC", 6);
    wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
    liquidityVault = new CollarLiquidityVault(usdc, "Collar USDC", "cUSDC", address(this));
    bridge = new MockBridge(wbtc);
    connector = new MockConnector(0);
    eulerAdapter = new MockEulerAdapter();
    messenger = new MockLZMessenger();
    borrower = vm.addr(borrowerKey);
    address permit2Address = new DeployPermit2().deployPermit2();
    permit2 = IAllowanceTransfer(permit2Address);
    permit2Signer = new Permit2ECDSASigner(permit2Address);

    vault =
      new CollarVault(
        address(this),
        ILiquidityVault(address(liquidityVault)),
        address(this),
        IEulerAdapter(address(eulerAdapter)),
        permit2,
        l2Recipient,
        treasury
      );

    liquidityVault.grantRole(liquidityVault.VAULT_ROLE(), address(vault));
    vault.grantRole(vault.KEEPER_ROLE(), keeper);
    vault.grantRole(vault.EXECUTOR_ROLE(), executor);

    mmSigner = vm.addr(mmKey);
    vault.setQuoteSigner(mmSigner, true);

    vault.setCollateralConfig(address(wbtc), true, 1e8);
    vault.setSocketBridgeConfig(address(wbtc), ISocketBridge(address(bridge)), ISocketConnector(address(connector)), 200_000, bytes(""), bytes(""));
    vault.setDeriveSubaccountId(1);
    vault.setPendingSubaccountId(2);
    vault.setTreasuryConfig(treasury, 2_000);
    vault.setLZMessenger(ICollarVaultMessenger(address(messenger)));

    address lender = address(0xCAFE);
    usdc.mint(lender, 1_000_000e6);
    vm.startPrank(lender);
    usdc.approve(address(liquidityVault), type(uint256).max);
    liquidityVault.deposit(1_000_000e6, lender);
    vm.stopPrank();

    wbtc.mint(borrower, 1e8);
    vm.startPrank(borrower);
    wbtc.approve(permit2Address, type(uint256).max);
    vm.stopPrank();
    permitNonce = 0;
  }

  function testCreateLoanHappyPath() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);
    bytes32 depositGuid = _depositConfirm(loanId, quote.collateralAsset, quote.collateralAmount);
    bytes32 tradeGuid = _tradeConfirm(loanId, quote, vault.hashQuote(quote), quote.nonce);

    vm.prank(keeper);
    uint256 createdLoanId = vault.finalizeLoan(loanId, depositGuid, tradeGuid);

    assertEq(createdLoanId, loanId);
    CollarVault.Loan memory loan = vault.getLoan(createdLoanId);
    assertEq(loan.borrower, borrower);
    assertEq(loan.principal, quote.borrowAmount);
    assertEq(uint256(loan.state), uint256(CollarVault.LoanState.ACTIVE_ZERO_COST));
    assertEq(usdc.balanceOf(borrower), quote.borrowAmount);
    assertEq(liquidityVault.activeLoans(), quote.borrowAmount);
  }

  function testCreateLoanRejectsExpiredQuote() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    quote.quoteExpiry = block.timestamp - 1;
    bytes memory sig = _signQuote(quote);
    IAllowanceTransfer.PermitSingle memory permit = _buildPermit(quote.collateralAsset, quote.collateralAmount);
    bytes memory permitSig = permit2Signer.signPermitSingle(borrowerKey, permit);

    vm.startPrank(borrower);
    vm.expectRevert(CollarVault.CV_QuoteExpired.selector);
    vault.createLoanWithPermit(quote, sig, permit, permitSig);
    vm.stopPrank();
  }

  function testCreateLoanRejectsInvalidSigner() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, vault.hashQuote(quote));
    bytes memory sig = abi.encodePacked(r, s, v);
    IAllowanceTransfer.PermitSingle memory permit = _buildPermit(quote.collateralAsset, quote.collateralAmount);
    bytes memory permitSig = permit2Signer.signPermitSingle(borrowerKey, permit);

    vm.startPrank(borrower);
    vm.expectRevert(CollarVault.CV_InvalidQuoteSigner.selector);
    vault.createLoanWithPermit(quote, sig, permit, permitSig);
    vm.stopPrank();
  }

  function testCreateLoanWithPermitRejectsTokenMismatch() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    IAllowanceTransfer.PermitSingle memory permit = _buildPermit(address(usdc), quote.collateralAmount);

    vm.startPrank(borrower);
    vm.expectRevert(CollarVault.CV_PermitTokenMismatch.selector);
    vault.createLoanWithPermit(quote, sig, permit, bytes("bad"));
    vm.stopPrank();
  }

  function testCreateLoanWithPermitRejectsSpenderMismatch() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    IAllowanceTransfer.PermitSingle memory permit = _buildPermit(quote.collateralAsset, quote.collateralAmount);
    permit.spender = address(0x1234);

    vm.startPrank(borrower);
    vm.expectRevert(CollarVault.CV_PermitSpenderMismatch.selector);
    vault.createLoanWithPermit(quote, sig, permit, bytes("bad"));
    vm.stopPrank();
  }

  function testCreateLoanWithPermitRejectsAmountTooLow() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    IAllowanceTransfer.PermitSingle memory permit = _buildPermit(quote.collateralAsset, quote.collateralAmount - 1);

    vm.startPrank(borrower);
    vm.expectRevert(CollarVault.CV_PermitAmountTooLow.selector);
    vault.createLoanWithPermit(quote, sig, permit, bytes("bad"));
    vm.stopPrank();
  }

  function testCreateLoanRejectsReplay() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    IAllowanceTransfer.PermitSingle memory permit = _buildPermit(quote.collateralAsset, quote.collateralAmount);
    bytes memory permitSig = permit2Signer.signPermitSingle(borrowerKey, permit);

    vm.startPrank(borrower);
    vault.createLoanWithPermit(quote, sig, permit, permitSig);
    assertTrue(vault.usedQuotes(vault.hashQuote(quote)));
    IAllowanceTransfer.PermitSingle memory nextPermit = _buildPermit(quote.collateralAsset, quote.collateralAmount);
    bytes memory nextPermitSig = permit2Signer.signPermitSingle(borrowerKey, nextPermit);
    vm.expectRevert(CollarVault.CV_QuoteUsed.selector);
    vault.createLoanWithPermit(quote, sig, nextPermit, nextPermitSig);
    vm.stopPrank();
  }

  function testFinalizeLoanRequiresKeeper() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);
    bytes32 depositGuid = _depositConfirm(loanId, quote.collateralAsset, quote.collateralAmount);
    bytes32 tradeGuid = _tradeConfirm(loanId, quote, vault.hashQuote(quote), quote.nonce);

    vm.startPrank(borrower);
    vm.expectRevert(CollarVault.CV_NotAuthorized.selector);
    vault.finalizeLoan(loanId, depositGuid, tradeGuid);
    vm.stopPrank();
  }

  function testRequestCollateralReturnSendsLZMessage() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);

    vm.prank(keeper);
    bytes32 guid = vault.requestCollateralReturn(loanId);

    CollarLZMessages.Message memory message = messenger.getLastSentMessage();
    assertEq(uint8(message.action), uint8(CollarLZMessages.Action.ReturnRequest));
    assertEq(message.loanId, loanId);
    assertEq(message.asset, quote.collateralAsset);
    assertEq(message.amount, quote.collateralAmount);
    assertEq(message.recipient, address(vault));
    assertEq(message.subaccountId, vault.pendingSubaccountId());
    assertEq(guid, messenger.lastSentGuid());
  }

  function testRequestCollateralReturnRevertsAfterTradeConfirmed() public {
    CollarVault.Quote memory quote = _quote(2, borrower);
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);
    bytes32 tradeGuid = _tradeConfirm(loanId, quote, vault.hashQuote(quote), quote.nonce);

    vault.recordTradeConfirmed(tradeGuid);

    vm.prank(keeper);
    vm.expectRevert(CollarVault.CV_PendingDepositReturnBlocked.selector);
    vault.requestCollateralReturn(loanId);
  }

  function testFinalizeDepositReturnRefundsBorrower() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);

    wbtc.mint(address(vault), quote.collateralAmount);

    vm.prank(keeper);
    vault.requestCollateralReturn(loanId);

    bytes32 guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.CollateralReturned,
        loanId: loanId,
        asset: address(wbtc),
        amount: quote.collateralAmount,
        recipient: address(vault),
        subaccountId: vault.pendingSubaccountId(),
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );

    uint256 borrowerBalance = wbtc.balanceOf(borrower);
    vault.finalizeDepositReturn(loanId, guid);

    assertEq(wbtc.balanceOf(borrower), borrowerBalance + quote.collateralAmount);
    (address pendingBorrower,,,) = vault.pendingDeposits(loanId);
    assertEq(pendingBorrower, address(0));

    CollarVault.Loan memory loan = vault.getLoan(loanId);
    assertEq(uint256(loan.state), uint256(CollarVault.LoanState.NONE));
  }

  function testFinalizeDepositReturnRequiresPendingDeposit() public {
    uint256 loanId = 999;
    wbtc.mint(address(vault), 1e8);

    bytes32 guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.CollateralReturned,
        loanId: loanId,
        asset: address(wbtc),
        amount: 1e8,
        recipient: address(vault),
        subaccountId: vault.pendingSubaccountId(),
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );

    vm.expectRevert(CollarVault.CV_PendingDepositNotFound.selector);
    vault.finalizeDepositReturn(loanId, guid);
  }

  function testCreateLoanSetsCollateralActivatedAfterTrade() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);
    bytes32 depositGuid = _depositConfirm(loanId, quote.collateralAsset, quote.collateralAmount);
    bytes32 tradeGuid = _tradeConfirm(loanId, quote, vault.hashQuote(quote), quote.nonce);

    vm.prank(keeper);
    vault.finalizeLoan(loanId, depositGuid, tradeGuid);

    assertTrue(vault.collateralActivated(loanId));
  }

  function testSettleLoanPutItm() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    usdc.mint(address(vault), loan.principal + 10e6);

    bytes32 guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.SettlementReport,
        loanId: loanId,
        asset: address(usdc),
        amount: loan.principal + 10e6,
        recipient: address(vault),
        subaccountId: loan.subaccountId,
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.PutITM, guid);

    assertEq(liquidityVault.activeLoans(), 0);
    assertEq(usdc.balanceOf(treasury), 2e6);
    assertEq(usdc.balanceOf(address(liquidityVault)), 1_000_000e6 + 8e6);
    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
  }

  function testSettleLoanPutItmShortfall() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);
    uint256 shortfall = 4e6;
    uint256 settlementAmount = loan.principal - shortfall;

    usdc.mint(address(vault), settlementAmount);

    bytes32 guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.SettlementReport,
        loanId: loanId,
        asset: address(usdc),
        amount: settlementAmount,
        recipient: address(vault),
        subaccountId: loan.subaccountId,
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.PutITM, guid);

    assertEq(liquidityVault.activeLoans(), 0);
    assertEq(liquidityVault.totalAssets(), 1_000_000e6 - shortfall);
    assertEq(usdc.balanceOf(borrower), loan.principal);
    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
  }

  function testSettleLoanRequiresLZMessage() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);
    uint256 settlementAmount = loan.principal + 10e6;
    usdc.mint(address(vault), settlementAmount);

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vm.expectRevert(CollarVault.CV_LZMessageNotFound.selector);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.PutITM, bytes32(uint256(1)));
  }

  function testSettleLoanCallItm() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    usdc.mint(address(vault), loan.principal + 5e6);

    bytes32 guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.SettlementReport,
        loanId: loanId,
        asset: address(usdc),
        amount: loan.principal + 5e6,
        recipient: address(vault),
        subaccountId: loan.subaccountId,
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.CallITM, guid);

    assertEq(liquidityVault.activeLoans(), 0);
    assertEq(usdc.balanceOf(borrower), loan.principal + 5e6);
    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
  }

  function testSettleLoanCallItmShortfall() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);
    uint256 shortfall = 3e6;
    uint256 settlementAmount = loan.principal - shortfall;

    usdc.mint(address(vault), settlementAmount);

    bytes32 guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.SettlementReport,
        loanId: loanId,
        asset: address(usdc),
        amount: settlementAmount,
        recipient: address(vault),
        subaccountId: loan.subaccountId,
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.CallITM, guid);

    assertEq(liquidityVault.activeLoans(), 0);
    assertEq(liquidityVault.totalAssets(), 1_000_000e6 - shortfall);
    assertEq(usdc.balanceOf(borrower), loan.principal);
    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
  }

  function testSettleLoanRejectsDoubleSettlement() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);
    usdc.mint(address(vault), loan.principal);

    bytes32 guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.SettlementReport,
        loanId: loanId,
        asset: address(usdc),
        amount: loan.principal,
        recipient: address(vault),
        subaccountId: loan.subaccountId,
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.CallITM, guid);

    vm.prank(keeper);
    vm.expectRevert(CollarVault.CV_InvalidLoanState.selector);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.CallITM, guid);
  }

  function testSettleLoanBeforeMaturityReverts() public {
    uint256 loanId = _createLoan();
    vm.prank(keeper);
    vm.expectRevert(CollarVault.CV_NotMatured.selector);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.CallITM, bytes32(uint256(1)));
  }

  function testNeutralConversionAndRepay() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    wbtc.mint(address(vault), loan.collateralAmount);
    usdc.mint(address(eulerAdapter), loan.principal);

    bytes32 guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.CollateralReturned,
        loanId: loanId,
        asset: address(wbtc),
        amount: loan.collateralAmount,
        recipient: address(vault),
        subaccountId: loan.subaccountId,
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.Neutral, guid);

    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.ACTIVE_VARIABLE));
    assertEq(eulerAdapter.debts(borrower), loan.principal);

    usdc.mint(borrower, loan.principal);
    vm.startPrank(borrower);
    usdc.approve(address(vault), loan.principal);
    vault.repayVariable(loanId);
    vm.stopPrank();

    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
    assertEq(wbtc.balanceOf(borrower), loan.collateralAmount);
  }

  function testFuzzSettlementAmount(uint256 excess) public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    excess = bound(excess, 0, 50e6);
    uint256 settlementAmount = loan.principal + excess;
    usdc.mint(address(vault), settlementAmount);

    bytes32 guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.SettlementReport,
        loanId: loanId,
        asset: address(usdc),
        amount: settlementAmount,
        recipient: address(vault),
        subaccountId: loan.subaccountId,
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.PutITM, guid);

    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
  }

  function testFuzzQuoteExpiry(uint256 expiryOffset) public {
    expiryOffset = bound(expiryOffset, 1, 10 days);
    CollarVault.Quote memory quote = _quote(1, borrower);
    quote.quoteExpiry = block.timestamp + expiryOffset;
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);
    bytes32 depositGuid = _depositConfirm(loanId, quote.collateralAsset, quote.collateralAmount);
    bytes32 tradeGuid = _tradeConfirm(loanId, quote, vault.hashQuote(quote), quote.nonce);

    vm.prank(keeper);
    vault.finalizeLoan(loanId, depositGuid, tradeGuid);
  }

  function testFuzzOriginationFee(uint96 principal, uint96 feeApr, uint32 duration) public {
    principal = uint96(bound(principal, 1e6, 100_000e6));
    feeApr = uint96(bound(feeApr, 0, 1e18));
    duration = uint32(bound(duration, 1 days, 180 days));

    vault.setOriginationFeeApr(feeApr);

    CollarVault.Quote memory quote = _quote(4, borrower);
    quote.putStrike = principal;
    quote.borrowAmount = principal;
    quote.maturity = block.timestamp + duration;
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);
    bytes32 depositGuid = _depositConfirm(loanId, quote.collateralAsset, quote.collateralAmount);
    bytes32 tradeGuid = _tradeConfirm(loanId, quote, vault.hashQuote(quote), quote.nonce);

    vm.prank(keeper);
    uint256 createdLoanId = vault.finalizeLoan(loanId, depositGuid, tradeGuid);

    uint256 annualFee = (uint256(principal) * feeApr) / 1e18;
    uint256 expectedFee = (annualFee * duration) / 365 days;
    assertEq(vault.calculateOriginationFee(createdLoanId), expectedFee);
  }

  function testCreateLoanZeroStrikeReverts() public {
    CollarVault.Quote memory quote = _quote(5, borrower);
    quote.putStrike = 0;
    quote.borrowAmount = 0;
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);
    bytes32 depositGuid = _depositConfirm(loanId, quote.collateralAsset, quote.collateralAmount);
    bytes32 tradeGuid = _tradeConfirm(loanId, quote, vault.hashQuote(quote), quote.nonce);

    vm.expectRevert(CollarLiquidityVault.LV_InvalidAmount.selector);
    vm.prank(keeper);
    vault.finalizeLoan(loanId, depositGuid, tradeGuid);
  }

  function testCreateLoanLargeStrike() public {
    address lender = address(0xD00D);
    usdc.mint(lender, 2_000_000e6);
    vm.startPrank(lender);
    usdc.approve(address(liquidityVault), type(uint256).max);
    liquidityVault.deposit(2_000_000e6, lender);
    vm.stopPrank();

    CollarVault.Quote memory quote = _quote(6, borrower);
    quote.putStrike = 500_000e6;
    quote.borrowAmount = 500_000e6;
    bytes memory sig = _signQuote(quote);
    uint256 loanId = _requestLoan(quote, sig);
    bytes32 depositGuid = _depositConfirm(loanId, quote.collateralAsset, quote.collateralAmount);
    bytes32 tradeGuid = _tradeConfirm(loanId, quote, vault.hashQuote(quote), quote.nonce);

    vm.prank(keeper);
    uint256 createdLoanId = vault.finalizeLoan(loanId, depositGuid, tradeGuid);

    assertEq(usdc.balanceOf(borrower), quote.borrowAmount);
    assertEq(createdLoanId, loanId);
  }

  function _createLoan() internal returns (uint256 loanId) {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);
    loanId = _requestLoan(quote, sig);
    bytes32 depositGuid = _depositConfirm(loanId, quote.collateralAsset, quote.collateralAmount);
    bytes32 tradeGuid = _tradeConfirm(loanId, quote, vault.hashQuote(quote), quote.nonce);

    vm.prank(keeper);
    uint256 createdLoanId = vault.finalizeLoan(loanId, depositGuid, tradeGuid);
    assertEq(createdLoanId, loanId);
  }

  function _quote(uint256 nonce, address quoteBorrower) internal view returns (CollarVault.Quote memory) {
    return _quoteWithAsset(nonce, quoteBorrower, address(wbtc));
  }

  function _quoteWithAsset(uint256 nonce, address quoteBorrower, address asset)
    internal
    view
    returns (CollarVault.Quote memory)
  {
    return CollarVault.Quote({
      collateralAsset: asset,
      collateralAmount: 1e8,
      maturity: block.timestamp + 30 days,
      putStrike: 20_000e6,
      callStrike: 25_000e6,
      borrowAmount: 20_000e6,
      quoteExpiry: block.timestamp + 1 days,
      borrower: quoteBorrower,
      nonce: nonce
    });
  }

  function _signQuote(CollarVault.Quote memory quote) internal view returns (bytes memory) {
    bytes32 digest = vault.hashQuote(quote);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
    return abi.encodePacked(r, s, v);
  }

  function _recordLZMessage(CollarLZMessages.Message memory message) internal returns (bytes32 guid) {
    guid = keccak256(abi.encodePacked(message.action, message.loanId, message.asset, message.amount, block.timestamp));
    messenger.setMessage(guid, message);
  }

  function _depositConfirm(uint256 loanId, address asset, uint256 amount) internal returns (bytes32 guid) {
    guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.DepositConfirmed,
        loanId: loanId,
        asset: asset,
        amount: amount,
        recipient: address(vault),
        subaccountId: vault.pendingSubaccountId(),
        socketMessageId: bytes32(0),
        secondaryAmount: 0,
        quoteHash: bytes32(0),
        takerNonce: 0
      })
    );
  }

  function _tradeConfirm(
    uint256 loanId,
    CollarVault.Quote memory quote,
    bytes32 quoteHash,
    uint256 takerNonce
  ) internal returns (bytes32 guid) {
    uint256 feeAmount = _expectedOriginationFee(quote);
    bytes32 socketMessageId = feeAmount == 0 ? bytes32(0) : bytes32(uint256(1));
    if (feeAmount > 0) {
      usdc.mint(address(vault), feeAmount);
    }
    guid = _recordLZMessage(
      CollarLZMessages.Message({
        action: CollarLZMessages.Action.TradeConfirmed,
        loanId: loanId,
        asset: address(usdc),
        amount: feeAmount,
        recipient: address(vault),
        subaccountId: vault.deriveSubaccountId(),
        socketMessageId: socketMessageId,
        secondaryAmount: 0,
        quoteHash: quoteHash,
        takerNonce: takerNonce
      })
    );
  }

  function _expectedOriginationFee(CollarVault.Quote memory quote) internal view returns (uint256) {
    uint256 feeApr = vault.originationFeeApr();
    if (feeApr == 0 || quote.maturity <= block.timestamp) {
      return 0;
    }
    uint256 duration = quote.maturity - block.timestamp;
    uint256 annualFee = (quote.borrowAmount * feeApr) / 1e18;
    return (annualFee * duration) / 365 days;
  }

  function _buildPermit(address token, uint256 amount)
    internal
    returns (IAllowanceTransfer.PermitSingle memory permit)
  {
    permit = IAllowanceTransfer.PermitSingle({
      details: IAllowanceTransfer.PermitDetails({
        token: token,
        amount: uint160(amount),
        expiration: uint48(block.timestamp + 1 days),
        nonce: permitNonce++
      }),
      spender: address(vault),
      sigDeadline: block.timestamp + 1 days
    });
  }

  function _requestLoan(CollarVault.Quote memory quote, bytes memory sig) internal returns (uint256 loanId) {
    IAllowanceTransfer.PermitSingle memory permit = _buildPermit(quote.collateralAsset, quote.collateralAmount);
    bytes memory permitSig = permit2Signer.signPermitSingle(borrowerKey, permit);

    vm.startPrank(borrower);
    (loanId,,) = vault.createLoanWithPermit(quote, sig, permit, permitSig);
    vm.stopPrank();
  }
}

contract MockLZMessenger {
  mapping(bytes32 => CollarLZMessages.Message) public receivedMessages;
  CollarLZMessages.Message public lastSentMessage;
  bytes32 public lastSentGuid;
  bytes public defaultOptions;
  uint256 public quoteFee;
  uint64 public nonce;

  function setQuoteFee(uint256 fee) external {
    quoteFee = fee;
  }

  function setDefaultOptions(bytes calldata options) external {
    defaultOptions = options;
  }

  function quoteMessage(CollarLZMessages.Message calldata, bytes calldata)
    external
    view
    returns (MessagingFee memory)
  {
    return MessagingFee({nativeFee: quoteFee, lzTokenFee: 0});
  }

  function sendMessage(CollarLZMessages.Message calldata message)
    external
    payable
    returns (MessagingReceipt memory)
  {
    nonce++;
    bytes32 guid = keccak256(abi.encodePacked(nonce, message.loanId, message.action));
    lastSentMessage = message;
    lastSentGuid = guid;
    return MessagingReceipt({guid: guid, nonce: nonce, fee: MessagingFee(msg.value, 0)});
  }

  function setMessage(bytes32 guid, CollarLZMessages.Message memory message) external {
    receivedMessages[guid] = message;
  }

  function getLastSentMessage() external view returns (CollarLZMessages.Message memory) {
    return lastSentMessage;
  }
}
