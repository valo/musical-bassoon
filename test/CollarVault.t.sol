// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CollarLiquidityVault} from "../src/CollarLiquidityVault.sol";
import {CollarVault, ILiquidityVault} from "../src/CollarVault.sol";
import {IEulerAdapter} from "../src/interfaces/IEulerAdapter.sol";
import {ISocketBridge} from "../src/interfaces/ISocketBridge.sol";
import {ISocketConnector} from "../src/interfaces/ISocketConnector.sol";
import {IMatching} from "v2-matching/src/interfaces/IMatching.sol";

import {MockBridge} from "./mocks/MockBridge.sol";
import {MockConnector} from "./mocks/MockConnector.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockEulerAdapter} from "./mocks/MockEulerAdapter.sol";
import {MockMatching} from "./mocks/MockMatching.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";

contract CollarVaultTest is Test {
  MockERC20 internal usdc;
  MockERC20 internal wbtc;
  CollarLiquidityVault internal liquidityVault;
  MockBridge internal bridge;
  MockConnector internal connector;
  MockEulerAdapter internal eulerAdapter;
  MockMatching internal matching;
  CollarVault internal vault;

  address internal borrower = address(0xB0B0);
  address internal treasury = address(0xB0B1);
  address internal keeper = address(0xA11CE);
  address internal executor = address(0xE1E1);
  address internal l2Recipient = address(0x1001);

  uint256 internal mmKey = 0xBEEF;
  address internal mmSigner;

  function setUp() public {
    usdc = new MockERC20("USD Coin", "USDC", 6);
    wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
    liquidityVault = new CollarLiquidityVault(usdc, "Collar USDC", "cUSDC", address(this));
    bridge = new MockBridge(wbtc);
    connector = new MockConnector(0);
    eulerAdapter = new MockEulerAdapter();
    matching = new MockMatching(keccak256("MOCK_DOMAIN"));

    vault =
      new CollarVault(address(this), ILiquidityVault(address(liquidityVault)), address(this), IEulerAdapter(address(eulerAdapter)), IMatching(address(matching)), l2Recipient, treasury);

    liquidityVault.grantRole(liquidityVault.VAULT_ROLE(), address(vault));
    vault.grantRole(vault.KEEPER_ROLE(), keeper);
    vault.grantRole(vault.EXECUTOR_ROLE(), executor);

    mmSigner = vm.addr(mmKey);
    vault.setQuoteSigner(mmSigner, true);

    vault.setCollateralConfig(address(wbtc), true, 1e8);
    vault.setSocketBridgeConfig(address(wbtc), ISocketBridge(address(bridge)), ISocketConnector(address(connector)), 200_000, bytes(""), bytes(""));
    vault.setDeriveSubaccountId(1);
    vault.setTreasuryConfig(treasury, 2_000);
    vault.setReceiptRelayer(address(this));

    address lender = address(0xCAFE);
    usdc.mint(lender, 1_000_000e6);
    vm.startPrank(lender);
    usdc.approve(address(liquidityVault), type(uint256).max);
    liquidityVault.deposit(1_000_000e6, lender);
    vm.stopPrank();

    wbtc.mint(borrower, 1e8);
  }

  function testCreateLoanHappyPath() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount);
    uint256 loanId = vault.createLoan(quote, sig);
    vm.stopPrank();

    CollarVault.Loan memory loan = vault.getLoan(loanId);
    assertEq(loan.borrower, borrower);
    assertEq(loan.principal, quote.borrowAmount);
    assertEq(uint256(loan.state), uint256(CollarVault.LoanState.ACTIVE_ZERO_COST));
    assertEq(usdc.balanceOf(borrower), quote.borrowAmount);
    assertEq(wbtc.balanceOf(address(bridge)), quote.collateralAmount);
    assertEq(liquidityVault.activeLoans(), quote.borrowAmount);
  }

  function testCreateLoanRequiresReceiptWhenEnabled() public {
    vault.setReceiptRequirements(true, false, false);
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount);
    vm.expectRevert(CollarVault.CV_ReceiptNotFound.selector);
    vault.createLoan(quote, sig);
    vm.stopPrank();

    _recordReceipt(
      vault.nextLoanId(),
      CollarVault.HookAction.DepositCollateral,
      address(wbtc),
      quote.collateralAmount
    );

    vm.startPrank(borrower);
    vault.createLoan(quote, sig);
    vm.stopPrank();
  }

  function testCreateLoanRejectsExpiredQuote() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    quote.quoteExpiry = block.timestamp - 1;
    bytes memory sig = _signQuote(quote);

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount);
    vm.expectRevert(CollarVault.CV_QuoteExpired.selector);
    vault.createLoan(quote, sig);
    vm.stopPrank();
  }

  function testCreateLoanRejectsInvalidSigner() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, vault.hashQuote(quote));
    bytes memory sig = abi.encodePacked(r, s, v);

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount);
    vm.expectRevert(CollarVault.CV_InvalidQuoteSigner.selector);
    vault.createLoan(quote, sig);
    vm.stopPrank();
  }

  function testCreateLoanRejectsReplay() public {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount * 2);
    vault.createLoan(quote, sig);
    vm.expectRevert(CollarVault.CV_QuoteUsed.selector);
    vault.createLoan(quote, sig);
    vm.stopPrank();
  }

  function testSettleLoanPutItm() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    usdc.mint(address(vault), loan.principal + 10e6);

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.PutITM, loan.principal + 10e6, 0);

    assertEq(liquidityVault.activeLoans(), 0);
    assertEq(usdc.balanceOf(treasury), 2e6);
    assertEq(usdc.balanceOf(address(liquidityVault)), 1_000_000e6 + 8e6);
    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
  }

  function testSettleLoanRequiresReceiptWhenEnabled() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);
    uint256 settlementAmount = loan.principal + 10e6;
    usdc.mint(address(vault), settlementAmount);

    vault.setReceiptRequirements(false, true, false);

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vm.expectRevert(CollarVault.CV_ReceiptNotFound.selector);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.PutITM, settlementAmount, 0);

    _recordReceipt(loanId, CollarVault.HookAction.SettleUSDC, address(usdc), settlementAmount);

    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.PutITM, settlementAmount, 0);
  }

  function testSettleLoanCallItm() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    usdc.mint(address(vault), loan.principal + 5e6);

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.CallITM, loan.principal + 5e6, 0);

    assertEq(liquidityVault.activeLoans(), 0);
    assertEq(usdc.balanceOf(borrower), loan.principal + 5e6);
    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
  }

  function testSettleLoanRejectsDoubleSettlement() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);
    usdc.mint(address(vault), loan.principal);

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.CallITM, loan.principal, 0);

    vm.prank(keeper);
    vm.expectRevert(CollarVault.CV_InvalidLoanState.selector);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.CallITM, loan.principal, 0);
  }

  function testSettleLoanBeforeMaturityReverts() public {
    uint256 loanId = _createLoan();
    vm.prank(keeper);
    vm.expectRevert(CollarVault.CV_NotMatured.selector);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.CallITM, 0, 0);
  }

  function testNeutralConversionAndRepay() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    wbtc.mint(address(vault), loan.collateralAmount);
    usdc.mint(address(eulerAdapter), loan.principal);

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.Neutral, 0, loan.collateralAmount);

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

  function testNeutralConversionRequiresReceiptWhenEnabled() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    wbtc.mint(address(vault), loan.collateralAmount);
    usdc.mint(address(eulerAdapter), loan.principal);

    vault.setReceiptRequirements(false, false, true);

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vm.expectRevert(CollarVault.CV_ReceiptNotFound.selector);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.Neutral, 0, loan.collateralAmount);

    _recordReceipt(loanId, CollarVault.HookAction.ReturnCollateral, address(wbtc), loan.collateralAmount);

    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.Neutral, 0, loan.collateralAmount);
  }

  function testRollLoanToNew() public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    wbtc.mint(address(vault), loan.collateralAmount);
    usdc.mint(address(eulerAdapter), loan.principal);

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.Neutral, 0, loan.collateralAmount);

    CollarVault.Quote memory quote = _quote(2, borrower);
    quote.borrowAmount = loan.principal + 3e6;
    quote.putStrike = 20003e6;
    bytes memory sig = _signQuote(quote);

    vm.prank(executor);
    uint256 newLoanId = vault.rollLoanToNew(loanId, quote, sig);

    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
    assertEq(uint256(vault.getLoan(newLoanId).state), uint256(CollarVault.LoanState.ACTIVE_ZERO_COST));
    assertEq(usdc.balanceOf(borrower), quote.borrowAmount);
    assertEq(wbtc.balanceOf(address(bridge)), loan.collateralAmount * 2);
  }

  function testFuzzSettlementAmount(uint256 excess) public {
    uint256 loanId = _createLoan();
    CollarVault.Loan memory loan = vault.getLoan(loanId);

    excess = bound(excess, 0, 50e6);
    uint256 settlementAmount = loan.principal + excess;
    usdc.mint(address(vault), settlementAmount);

    vm.warp(loan.maturity + 1);
    vm.prank(keeper);
    vault.settleLoan(loanId, CollarVault.SettlementOutcome.PutITM, settlementAmount, 0);

    assertEq(uint256(vault.getLoan(loanId).state), uint256(CollarVault.LoanState.CLOSED));
  }

  function testFuzzQuoteExpiry(uint256 expiryOffset) public {
    expiryOffset = bound(expiryOffset, 1, 10 days);
    CollarVault.Quote memory quote = _quote(1, borrower);
    quote.quoteExpiry = block.timestamp + expiryOffset;
    bytes memory sig = _signQuote(quote);

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount);
    vault.createLoan(quote, sig);
    vm.stopPrank();
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

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount);
    uint256 loanId = vault.createLoan(quote, sig);
    vm.stopPrank();

    uint256 annualFee = (uint256(principal) * feeApr) / 1e18;
    uint256 expectedFee = (annualFee * duration) / 365 days;
    assertEq(vault.calculateOriginationFee(loanId), expectedFee);
  }

  function testCreateLoanReentrancyGuard() public {
    ReentrantERC20 reentrant = new ReentrantERC20("Reenter", "RE", 8);
    vault.setCollateralConfig(address(reentrant), true, 1e8);
    MockBridge reentrantBridge = new MockBridge(reentrant);
    vault.setSocketBridgeConfig(address(reentrant), ISocketBridge(address(reentrantBridge)), ISocketConnector(address(connector)), 200_000, bytes(""), bytes(""));

    reentrant.mint(borrower, 1e8);
    CollarVault.Quote memory quote = _quoteWithAsset(3, borrower, address(reentrant));
    quote.borrower = address(0);
    bytes memory sig = _signQuote(quote);

    reentrant.arm(address(vault), abi.encodeWithSelector(vault.createLoan.selector, quote, sig));

    vm.startPrank(borrower);
    reentrant.approve(address(vault), quote.collateralAmount);
    vm.expectRevert();
    vault.createLoan(quote, sig);
    vm.stopPrank();
  }

  function testCreateLoanZeroStrikeReverts() public {
    CollarVault.Quote memory quote = _quote(5, borrower);
    quote.putStrike = 0;
    quote.borrowAmount = 0;
    bytes memory sig = _signQuote(quote);

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount);
    vm.expectRevert(CollarLiquidityVault.LV_InvalidAmount.selector);
    vault.createLoan(quote, sig);
    vm.stopPrank();
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

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount);
    vault.createLoan(quote, sig);
    vm.stopPrank();

    assertEq(usdc.balanceOf(borrower), quote.borrowAmount);
  }

  function _createLoan() internal returns (uint256 loanId) {
    CollarVault.Quote memory quote = _quote(1, borrower);
    bytes memory sig = _signQuote(quote);

    vm.startPrank(borrower);
    wbtc.approve(address(vault), quote.collateralAmount);
    loanId = vault.createLoan(quote, sig);
    vm.stopPrank();
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

  function _recordReceipt(
    uint256 loanId,
    CollarVault.HookAction action,
    address asset,
    uint256 amount
  ) internal returns (bytes32 messageId) {
    messageId = keccak256(abi.encodePacked(loanId, action, asset, amount, block.number));
    vault.recordHookReceipt(
      CollarVault.HookReceipt({
        action: action,
        loanId: loanId,
        asset: asset,
        amount: amount,
        recipient: borrower,
        messageId: messageId,
        success: true
      })
    );
  }
}
