// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {IActionVerifier} from "v2-matching/src/interfaces/IActionVerifier.sol";
import {IRfqModule} from "v2-matching/src/interfaces/IRfqModule.sol";
import {OptionEncoding} from "lyra-utils/encoding/OptionEncoding.sol";

import {CollarTSA} from "../src/CollarTSA.sol";
import {CollarTSATestUtils} from "./utils/CollarTSATestUtils.sol";

contract CollarTSA_ValidationTests is CollarTSATestUtils {
  function setUp() public override {
    MARKET = "weth";
    super.setUp();
    deployPredeposit(address(0));
    upgradeToCollarTSA(MARKET);
    setupCollarTSA();
  }

  function testAllowsShortCallAndLongPut() public {
    _depositToTSA(10e18);
    _executeDeposit(10e18);

    uint64 expiry = uint64(block.timestamp + 7 days);
    _setForwardPrice(MARKET, expiry, 2000e18, 1e18);
    _setFixedSVIDataForExpiry(MARKET, expiry);

    IRfqModule.TradeData[] memory trades = new IRfqModule.TradeData[](2);
    trades[0] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 2200e18, true),
      price: 100e18,
      amount: -1e18
    });
    trades[1] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 1800e18, false),
      price: 1e18,
      amount: 1e18
    });

    IRfqModule.RfqOrder memory order = IRfqModule.RfqOrder({maxFee: 0, trades: trades});

    IActionVerifier.Action memory action = IActionVerifier.Action({
      subaccountId: tsaSubacc,
      nonce: ++tsaNonce,
      module: rfqModule,
      data: abi.encode(order),
      expiry: block.timestamp + 8 minutes,
      owner: address(tsa),
      signer: address(tsa)
    });

    vm.prank(signer);
    collarTsa.signActionData(action, "");
  }

  function testRejectsLongCall() public {
    _depositToTSA(1e18);
    _executeDeposit(1e18);

    uint64 expiry = uint64(block.timestamp + 7 days);
    _setForwardPrice(MARKET, expiry, 2000e18, 1e18);
    _setFixedSVIDataForExpiry(MARKET, expiry);

    IRfqModule.TradeData[] memory trades = new IRfqModule.TradeData[](2);
    trades[0] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 2200e18, true),
      price: 100e18,
      amount: 1e18
    });
    trades[1] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 1800e18, false),
      price: 1e18,
      amount: 1e18
    });

    IRfqModule.RfqOrder memory order = IRfqModule.RfqOrder({maxFee: 0, trades: trades});

    IActionVerifier.Action memory action = IActionVerifier.Action({
      subaccountId: tsaSubacc,
      nonce: ++tsaNonce,
      module: rfqModule,
      data: abi.encode(order),
      expiry: block.timestamp + 8 minutes,
      owner: address(tsa),
      signer: address(tsa)
    });

    vm.prank(signer);
    vm.expectRevert(CollarTSA.CTSA_CanOnlyOpenShortCalls.selector);
    collarTsa.signActionData(action, "");
  }

  function testRejectsShortPut() public {
    _depositToTSA(1e18);
    _executeDeposit(1e18);

    uint64 expiry = uint64(block.timestamp + 7 days);
    _setForwardPrice(MARKET, expiry, 2000e18, 1e18);
    _setFixedSVIDataForExpiry(MARKET, expiry);

    IRfqModule.TradeData[] memory trades = new IRfqModule.TradeData[](2);
    trades[0] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 2200e18, true),
      price: 100e18,
      amount: -1e18
    });
    trades[1] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 1800e18, false),
      price: 1e18,
      amount: -1e18
    });

    IRfqModule.RfqOrder memory order = IRfqModule.RfqOrder({maxFee: 0, trades: trades});

    IActionVerifier.Action memory action = IActionVerifier.Action({
      subaccountId: tsaSubacc,
      nonce: ++tsaNonce,
      module: rfqModule,
      data: abi.encode(order),
      expiry: block.timestamp + 8 minutes,
      owner: address(tsa),
      signer: address(tsa)
    });

    vm.prank(signer);
    vm.expectRevert(CollarTSA.CTSA_OnlyLongPutsAllowed.selector);
    collarTsa.signActionData(action, "");
  }

  function testPutPriceTooHigh() public {
    _depositToTSA(1e18);
    _executeDeposit(1e18);

    uint64 expiry = uint64(block.timestamp + 7 days);
    _setForwardPrice(MARKET, expiry, 2000e18, 1e18);
    _setFixedSVIDataForExpiry(MARKET, expiry);

    CollarTSA.CollarTSAParams memory params = collarTsa.getCollarTSAParams();
    params.putMaxPriceFactor = 1e18;
    collarTsa.setCollarTSAParams(params);

    IRfqModule.TradeData[] memory trades = new IRfqModule.TradeData[](2);
    trades[0] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 2200e18, true),
      price: 100e18,
      amount: -1e18
    });
    trades[1] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 1800e18, false),
      price: 10_000e18,
      amount: 1e18
    });

    IRfqModule.RfqOrder memory order = IRfqModule.RfqOrder({maxFee: 0, trades: trades});

    IActionVerifier.Action memory action = IActionVerifier.Action({
      subaccountId: tsaSubacc,
      nonce: ++tsaNonce,
      module: rfqModule,
      data: abi.encode(order),
      expiry: block.timestamp + 8 minutes,
      owner: address(tsa),
      signer: address(tsa)
    });

    vm.prank(signer);
    vm.expectRevert(CollarTSA.CTSA_PutPriceTooHigh.selector);
    collarTsa.signActionData(action, "");
  }

  function testRejectsTakerOrderHashMismatch() public {
    _depositToTSA(1e18);
    _executeDeposit(1e18);

    uint64 expiry = uint64(block.timestamp + 7 days);
    IRfqModule.TradeData[] memory trades = new IRfqModule.TradeData[](2);
    trades[0] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 2200e18, true),
      price: 100e18,
      amount: 1e18
    });
    trades[1] = IRfqModule.TradeData({
      asset: address(markets[MARKET].option),
      subId: OptionEncoding.toSubId(expiry, 1800e18, false),
      price: 1e18,
      amount: -1e18
    });

    IRfqModule.TakerOrder memory order =
      IRfqModule.TakerOrder({orderHash: keccak256("mismatch"), maxFee: 0});

    IActionVerifier.Action memory action = IActionVerifier.Action({
      subaccountId: tsaSubacc,
      nonce: ++tsaNonce,
      module: rfqModule,
      data: abi.encode(order),
      expiry: block.timestamp + 8 minutes,
      owner: address(tsa),
      signer: address(tsa)
    });

    vm.prank(signer);
    vm.expectRevert(CollarTSA.CTSA_TradeDataDoesNotMatchOrderHash.selector);
    collarTsa.signActionData(action, abi.encode(trades));
  }
}
