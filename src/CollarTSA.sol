// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {IntLib} from "lyra-utils/math/IntLib.sol";
import {OptionEncoding} from "lyra-utils/encoding/OptionEncoding.sol";
import {Black76} from "lyra-utils/math/Black76.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import {DecimalMath} from "lyra-utils/decimals/DecimalMath.sol";
import {SignedDecimalMath} from "lyra-utils/decimals/SignedDecimalMath.sol";
import {ConvertDecimals} from "lyra-utils/decimals/ConvertDecimals.sol";

import {BaseTSA} from "v2-matching/src/tokenizedSubaccounts/BaseOnChainSigningTSA.sol";
import {ISubAccounts} from "v2-core/src/interfaces/ISubAccounts.sol";
import {IOptionAsset} from "v2-core/src/interfaces/IOptionAsset.sol";
import {ISpotFeed} from "v2-core/src/interfaces/ISpotFeed.sol";
import {IDepositModule} from "v2-matching/src/interfaces/IDepositModule.sol";
import {IWithdrawalModule} from "v2-matching/src/interfaces/IWithdrawalModule.sol";
import {IMatching} from "v2-matching/src/interfaces/IMatching.sol";
import {ITradeModule} from "v2-matching/src/interfaces/ITradeModule.sol";
import {IRfqModule} from "v2-matching/src/interfaces/IRfqModule.sol";

import {
  StandardManager, IStandardManager, IVolFeed, IForwardFeed
} from "v2-core/src/risk-managers/StandardManager.sol";
import {CollateralManagementTSA} from "v2-matching/src/tokenizedSubaccounts/CollateralManagementTSA.sol";

/// @title CollarTSA
/// @notice TSA that allows selling covered calls and buying long puts for collar construction.
contract CollarTSA is CollateralManagementTSA {
  using IntLib for int;
  using SafeCast for int;
  using SafeCast for uint;
  using DecimalMath for uint;
  using SignedDecimalMath for int;

  struct CollarTSAInitParams {
    ISpotFeed baseFeed;
    IDepositModule depositModule;
    IWithdrawalModule withdrawalModule;
    ITradeModule tradeModule;
    IRfqModule rfqModule;
    IOptionAsset optionAsset;
  }

  struct CollarTSAParams {
    /// @dev Minimum time before an action is expired
    uint minSignatureExpiry;
    /// @dev Maximum time before an action is expired
    uint maxSignatureExpiry;
    /// @dev The worst difference to vol that is accepted for pricing options (e.g. 0.9e18)
    uint optionVolSlippageFactor;
    /// @dev The highest delta for calls accepted by the TSA after vol/fwd slippage is applied (e.g. 0.15e18).
    uint callMaxDelta;
    /// @dev Maximum amount of negative cash allowed when opening option positions. (e.g. -100e18)
    int maxNegCash;
    /// @dev Lower bound for option expiry
    uint optionMinTimeToExpiry;
    /// @dev Upper bound for option expiry
    uint optionMaxTimeToExpiry;
    /// @dev Maximum price factor for long puts relative to mark (e.g. 1.05e18).
    uint putMaxPriceFactor;
  }

  struct CollarLeg {
    IRfqModule.TradeData trade;
    uint expiry;
    uint strike;
  }

  /// @custom:storage-location erc7201:lyra.storage.CollarTSA
  struct CollarTSAStorage {
    IDepositModule depositModule;
    IWithdrawalModule withdrawalModule;
    ITradeModule tradeModule;
    IRfqModule rfqModule;
    IOptionAsset optionAsset;
    ISpotFeed baseFeed;
    CollarTSAParams params;
    CollateralManagementParams collateralManagementParams;
    /// @dev Only one hash is considered valid at a time, and it is revoked when a new one comes in.
    bytes32 lastSeenHash;
  }

  // keccak256(abi.encode(uint256(keccak256("lyra.storage.CollarTSA")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant CollarTSAStorageLocation = 0x62b72349c5c9dfc4c2d0e5f1b0600421e6f0d0f8ac3a0ffdf4c4c0b7d4b4b000;

  function _getCollarTSAStorage() private pure returns (CollarTSAStorage storage $) {
    assembly {
      $.slot := CollarTSAStorageLocation
    }
  }

  constructor() {
    _disableInitializers();
  }

  /// @notice Initialize the CollarTSA implementation.
  function initialize(
    address initialOwner,
    BaseTSA.BaseTSAInitParams memory initParams,
    CollarTSAInitParams memory collarInitParams
  ) external reinitializer(5) {
    __BaseTSA_init(initialOwner, initParams);

    CollarTSAStorage storage $ = _getCollarTSAStorage();

    $.depositModule = collarInitParams.depositModule;
    $.withdrawalModule = collarInitParams.withdrawalModule;
    $.tradeModule = collarInitParams.tradeModule;
    $.rfqModule = collarInitParams.rfqModule;
    $.optionAsset = collarInitParams.optionAsset;
    $.baseFeed = collarInitParams.baseFeed;

    BaseTSAAddresses memory tsaAddresses = getBaseTSAAddresses();
    tsaAddresses.depositAsset.approve(address($.depositModule), type(uint).max);
  }

  ///////////
  // Admin //
  ///////////

  /// @notice Set CollarTSA parameters.
  function setCollarTSAParams(CollarTSAParams memory newParams) external onlyOwner {
    if (
      newParams.minSignatureExpiry < 1 minutes || newParams.minSignatureExpiry > newParams.maxSignatureExpiry
        || newParams.optionVolSlippageFactor > 1e18 || newParams.callMaxDelta >= 0.5e18
        || newParams.optionMaxTimeToExpiry <= newParams.optionMinTimeToExpiry || newParams.maxNegCash > 0
        || newParams.putMaxPriceFactor < 1e18 || newParams.putMaxPriceFactor > 2e18
    ) {
      revert CTSA_InvalidParams();
    }

    _getCollarTSAStorage().params = newParams;
    emit CollarTSAParamsSet(newParams);
  }

  /// @notice Set collateral management parameters.
  function setCollateralManagementParams(CollateralManagementParams memory newCollateralMgmtParams)
    external
    override
    onlyOwner
  {
    if (
      newCollateralMgmtParams.worstSpotBuyPrice < 1e18 || newCollateralMgmtParams.worstSpotBuyPrice > 1.2e18
        || newCollateralMgmtParams.worstSpotSellPrice > 1e18 || newCollateralMgmtParams.worstSpotSellPrice < 0.8e18
        || newCollateralMgmtParams.spotTransactionLeniency < 1e18
        || newCollateralMgmtParams.spotTransactionLeniency > 1.2e18 || newCollateralMgmtParams.feeFactor > 0.05e18
    ) {
      revert CTSA_InvalidParams();
    }
    _getCollarTSAStorage().collateralManagementParams = newCollateralMgmtParams;

    emit CMTSAParamsSet(newCollateralMgmtParams);
  }

  function _getCollateralManagementParams() internal view override returns (CollateralManagementParams storage $) {
    return _getCollarTSAStorage().collateralManagementParams;
  }

  ///////////////////////
  // Action Validation //
  ///////////////////////

  function _verifyAction(IMatching.Action memory action, bytes32 actionHash, bytes memory extraData)
    internal
    virtual
    override
    checkBlocked
  {
    CollarTSAStorage storage $ = _getCollarTSAStorage();

    if (
      action.expiry < block.timestamp + $.params.minSignatureExpiry
        || action.expiry > block.timestamp + $.params.maxSignatureExpiry
    ) {
      revert CTSA_InvalidActionExpiry();
    }

    // Disable last seen hash when a new one comes in.
    _revokeSignature($.lastSeenHash);
    $.lastSeenHash = actionHash;

    BaseTSAAddresses memory tsaAddresses = getBaseTSAAddresses();

    if (address(action.module) == address($.depositModule)) {
      _verifyDepositAction(action, tsaAddresses);
    } else if (address(action.module) == address($.withdrawalModule)) {
      _verifyWithdrawAction(action, tsaAddresses);
    } else if (address(action.module) == address($.tradeModule)) {
      _verifyTradeAction(action, tsaAddresses);
    } else if (address(action.module) == address($.rfqModule)) {
      _verifyRfqAction(action, extraData);
    } else {
      revert CTSA_InvalidModule();
    }
  }

  /////////////////
  // Withdrawals //
  /////////////////

  function _verifyWithdrawAction(IMatching.Action memory action, BaseTSAAddresses memory tsaAddresses) internal view {
    IWithdrawalModule.WithdrawalData memory withdrawalData = abi.decode(action.data, (IWithdrawalModule.WithdrawalData));

    if (withdrawalData.asset != address(tsaAddresses.wrappedDepositAsset)) {
      revert CTSA_InvalidAsset();
    }

    (uint shortCalls, uint baseBalance, int cashBalance,,) = _getSubAccountStats();

    uint amount18 = ConvertDecimals.to18Decimals(withdrawalData.assetAmount, tsaAddresses.depositAsset.decimals());

    if (baseBalance < amount18 + shortCalls) {
      revert CTSA_WithdrawingUtilisedCollateral();
    }

    if (cashBalance < _getCollarTSAStorage().params.maxNegCash) {
      revert CTSA_WithdrawalNegativeCash();
    }
  }

  /////////////
  // Trading //
  /////////////

  function _verifyTradeAction(IMatching.Action memory action, BaseTSAAddresses memory tsaAddresses) internal view {
    ITradeModule.TradeData memory tradeData = abi.decode(action.data, (ITradeModule.TradeData));

    if (tradeData.desiredAmount <= 0) {
      revert CTSA_InvalidDesiredAmount();
    }

    if (tradeData.asset == address(tsaAddresses.wrappedDepositAsset)) {
      _tradeCollateral(tradeData);
    } else {
      revert CTSA_InvalidAsset();
    }
  }

  /// @dev If extraData is 0, the action is a maker action; otherwise, it is a taker action.
  function _verifyRfqAction(IMatching.Action memory action, bytes memory extraData) internal view {
    // TODO: Confirm whether RFQ maxFee should be bounded by on-chain parameters for collar trades.
    IRfqModule.TradeData[] memory makerTrades;
    if (extraData.length == 0) {
      IRfqModule.RfqOrder memory makerOrder = abi.decode(action.data, (IRfqModule.RfqOrder));
      makerTrades = makerOrder.trades;
    } else {
      IRfqModule.TakerOrder memory takerOrder = abi.decode(action.data, (IRfqModule.TakerOrder));
      if (keccak256(extraData) != takerOrder.orderHash) {
        revert CTSA_TradeDataDoesNotMatchOrderHash();
      }
      makerTrades = abi.decode(extraData, (IRfqModule.TradeData[]));
    }

    _verifyCollarRfqTrades(makerTrades, extraData.length != 0);
  }

  function _verifyCollarRfqTrades(IRfqModule.TradeData[] memory makerTrades, bool isTaker) internal view {
    CollarTSAStorage storage $ = _getCollarTSAStorage();
    (CollarLeg memory callLeg, CollarLeg memory putLeg) =
      _splitRfqLegs(makerTrades, address($.optionAsset));

    if (callLeg.expiry != putLeg.expiry) {
      revert CTSA_InvalidRfqTradeDetails();
    }

    int callAmount = isTaker ? -callLeg.trade.amount : callLeg.trade.amount;
    int putAmount = isTaker ? -putLeg.trade.amount : putLeg.trade.amount;

    if (callAmount >= 0) {
      revert CTSA_CanOnlyOpenShortCalls();
    }
    if (putAmount <= 0) {
      revert CTSA_OnlyLongPutsAllowed();
    }
    if (callAmount.abs() != putAmount.abs()) {
      revert CTSA_InvalidTradeAmount();
    }

    (uint shortCalls, uint baseBalance, int cashBalance,,) = _getSubAccountStats();
    if (shortCalls + callAmount.abs() > baseBalance) {
      revert CTSA_SellingTooManyCalls();
    }

    _validateCallDetails(callLeg.expiry, callLeg.strike, callLeg.trade.price);
    _validatePutDetails(putLeg.expiry, putLeg.strike, putLeg.trade.price);

    int cashDelta = callLeg.trade.price.toInt256().multiplyDecimal(callLeg.trade.amount)
      + putLeg.trade.price.toInt256().multiplyDecimal(putLeg.trade.amount);
    int postTradeCash = cashBalance + (isTaker ? cashDelta : -cashDelta);
    if (postTradeCash < $.params.maxNegCash) {
      revert CTSA_InsufficientCash();
    }
  }

  function _splitRfqLegs(IRfqModule.TradeData[] memory makerTrades, address optionAsset)
    internal
    pure
    returns (CollarLeg memory callLeg, CollarLeg memory putLeg)
  {
    if (makerTrades.length != 2) {
      revert CTSA_InvalidRfqTradeLength();
    }

    bool hasCall;
    bool hasPut;

    for (uint i = 0; i < makerTrades.length; i++) {
      if (makerTrades[i].asset != optionAsset) {
        revert CTSA_InvalidAsset();
      }

      (uint expiry, uint strike, bool isCall) = OptionEncoding.fromSubId(makerTrades[i].subId.toUint96());
      if (isCall) {
        if (hasCall) {
          revert CTSA_InvalidRfqTradeDetails();
        }
        callLeg = CollarLeg({trade: makerTrades[i], expiry: expiry, strike: strike});
        hasCall = true;
      } else {
        if (hasPut) {
          revert CTSA_InvalidRfqTradeDetails();
        }
        putLeg = CollarLeg({trade: makerTrades[i], expiry: expiry, strike: strike});
        hasPut = true;
      }
    }

    if (!hasCall || !hasPut) {
      revert CTSA_InvalidRfqTradeDetails();
    }
  }

  function _verifyCallSell(ITradeModule.TradeData memory tradeData, uint expiry, uint strike) internal view {
    (uint shortCalls, uint baseBalance, int cashBalance,,) = _getSubAccountStats();

    if (tradeData.desiredAmount.abs() + shortCalls > baseBalance) {
      revert CTSA_SellingTooManyCalls();
    }

    if (cashBalance < _getCollarTSAStorage().params.maxNegCash) {
      revert CTSA_CannotSellOptionsWithNegativeCash();
    }

    _verifyCollateralTradeFee(tradeData.worstFee, _getBasePrice());
    _validateCallDetails(expiry, strike, tradeData.limitPrice.toUint256());
  }

  function _verifyPutBuy(ITradeModule.TradeData memory tradeData, uint expiry, uint strike) internal view {
    (, , int cashBalance,,) = _getSubAccountStats();

    _verifyCollateralTradeFee(tradeData.worstFee, _getBasePrice());
    _validatePutDetails(expiry, strike, tradeData.limitPrice.toUint256());

    int cost = tradeData.limitPrice.multiplyDecimal(tradeData.desiredAmount);
    int remainingCash = cashBalance - cost;
    if (remainingCash < _getCollarTSAStorage().params.maxNegCash) {
      revert CTSA_InsufficientCash();
    }
  }

  /////////////////
  // Option Math //
  /////////////////

  function _validateCallDetails(uint expiry, uint strike, uint limitPrice) internal view {
    CollarTSAStorage storage $ = _getCollarTSAStorage();

    _validateExpiry(expiry);

    uint timeToExpiry = expiry - block.timestamp;
    (uint vol, uint forwardPrice) = _getFeedValues(strike.toUint128(), expiry.toUint64());

    (uint callPrice,, uint callDelta) = Black76.pricesAndDelta(
      Black76.Black76Inputs({
        timeToExpirySec: timeToExpiry.toUint64(),
        volatility: (vol.multiplyDecimal($.params.optionVolSlippageFactor)).toUint128(),
        fwdPrice: forwardPrice.toUint128(),
        strikePrice: strike.toUint128(),
        discount: 1e18
      })
    );

    if (callDelta > $.params.callMaxDelta) {
      revert CTSA_OptionDeltaTooHigh();
    }

    if (limitPrice <= callPrice) {
      revert CTSA_OptionPriceTooLow();
    }
  }

  function _validatePutDetails(uint expiry, uint strike, uint limitPrice) internal view {
    CollarTSAStorage storage $ = _getCollarTSAStorage();

    _validateExpiry(expiry);

    uint timeToExpiry = expiry - block.timestamp;
    (uint vol, uint forwardPrice) = _getFeedValues(strike.toUint128(), expiry.toUint64());

    (, uint putPrice,) = Black76.pricesAndDelta(
      Black76.Black76Inputs({
        timeToExpirySec: timeToExpiry.toUint64(),
        volatility: (vol.multiplyDecimal($.params.optionVolSlippageFactor)).toUint128(),
        fwdPrice: forwardPrice.toUint128(),
        strikePrice: strike.toUint128(),
        discount: 1e18
      })
    );

    uint maxPrice = putPrice.multiplyDecimal($.params.putMaxPriceFactor);
    if (limitPrice > maxPrice) {
      revert CTSA_PutPriceTooHigh();
    }
  }

  function _validateExpiry(uint expiry) internal view {
    CollarTSAStorage storage $ = _getCollarTSAStorage();

    if (block.timestamp >= expiry) {
      revert CTSA_OptionExpired();
    }
    uint timeToExpiry = expiry - block.timestamp;
    if (timeToExpiry < $.params.optionMinTimeToExpiry || timeToExpiry > $.params.optionMaxTimeToExpiry) {
      revert CTSA_OptionExpiryOutOfBounds();
    }
  }

  function _getFeedValues(uint128 strike, uint64 expiry) internal view returns (uint vol, uint forwardPrice) {
    CollarTSAStorage storage $ = _getCollarTSAStorage();

    StandardManager srm = StandardManager(address(getBaseTSAAddresses().manager));
    IStandardManager.AssetDetail memory assetDetails = srm.assetDetails($.optionAsset);
    (, IForwardFeed fwdFeed, IVolFeed volFeed) = srm.getMarketFeeds(assetDetails.marketId);
    (vol,) = volFeed.getVol(strike, expiry);
    (forwardPrice,) = fwdFeed.getForwardPrice(expiry);
  }

  ///////////////////
  // Account Value //
  ///////////////////

  /// @notice Get short calls, base balance, cash balance, and long puts in the subaccount.
  function _getSubAccountStats()
    internal
    view
    returns (uint shortCalls, uint baseBalance, int cashBalance, uint longPuts, uint optionPositions)
  {
    BaseTSAAddresses memory tsaAddresses = getBaseTSAAddresses();

    ISubAccounts.AssetBalance[] memory balances = tsaAddresses.subAccounts.getAccountBalances(subAccount());
    for (uint i = 0; i < balances.length; i++) {
      if (balances[i].asset == _getCollarTSAStorage().optionAsset) {
        int balance = balances[i].balance;
        if (balance == 0) {
          continue;
        }
        (,, bool isCall) = OptionEncoding.fromSubId(balances[i].subId.toUint96());
        if (balance > 0) {
          if (isCall) {
            revert CTSA_InvalidOptionBalance();
          }
          longPuts += balance.toUint256();
        } else {
          if (!isCall) {
            revert CTSA_InvalidOptionBalance();
          }
          shortCalls += balance.abs();
        }
        optionPositions += 1;
      } else if (balances[i].asset == tsaAddresses.wrappedDepositAsset) {
        baseBalance = balances[i].balance.abs();
      } else if (balances[i].asset == tsaAddresses.cash) {
        cashBalance = balances[i].balance;
      }
    }
    return (shortCalls, baseBalance, cashBalance, longPuts, optionPositions);
  }

  function _getBasePrice() internal view override returns (uint spotPrice) {
    (spotPrice,) = _getCollarTSAStorage().baseFeed.getSpot();
  }

  ///////////
  // Views //
  ///////////

  function getAccountValue(bool includePending) public view returns (uint) {
    return _getAccountValue(includePending);
  }

  function getSubAccountStats()
    public
    view
    returns (uint shortCalls, uint baseBalance, int cashBalance, uint longPuts, uint optionPositions)
  {
    return _getSubAccountStats();
  }

  function getBasePrice() public view returns (uint) {
    return _getBasePrice();
  }

  function getCollarTSAParams() public view returns (CollarTSAParams memory) {
    return _getCollarTSAStorage().params;
  }

  function getCollateralManagementParams() public view returns (CollateralManagementParams memory) {
    return _getCollateralManagementParams();
  }

  function lastSeenHash() public view returns (bytes32) {
    return _getCollarTSAStorage().lastSeenHash;
  }

  function getCollarTSAAddresses()
    public
    view
    returns (ISpotFeed, IDepositModule, IWithdrawalModule, ITradeModule, IRfqModule, IOptionAsset)
  {
    CollarTSAStorage storage $ = _getCollarTSAStorage();
    return ($.baseFeed, $.depositModule, $.withdrawalModule, $.tradeModule, $.rfqModule, $.optionAsset);
  }

  ///////////////////
  // Events/Errors //
  ///////////////////

  event CollarTSAParamsSet(CollarTSAParams params);

  error CTSA_InvalidParams();
  error CTSA_InvalidActionExpiry();
  error CTSA_InvalidModule();
  error CTSA_InvalidAsset();
  error CTSA_InvalidDesiredAmount();
  error CTSA_WithdrawingUtilisedCollateral();
  error CTSA_WithdrawalNegativeCash();
  error CTSA_SellingTooManyCalls();
  error CTSA_CannotSellOptionsWithNegativeCash();
  error CTSA_CanOnlyOpenShortCalls();
  error CTSA_OnlyLongPutsAllowed();
  error CTSA_OptionExpired();
  error CTSA_OptionDeltaTooHigh();
  error CTSA_OptionPriceTooLow();
  error CTSA_PutPriceTooHigh();
  error CTSA_InvalidOptionBalance();
  error CTSA_OptionExpiryOutOfBounds();
  error CTSA_InsufficientCash();
  error CTSA_InvalidRfqTradeLength();
  error CTSA_InvalidRfqTradeDetails();
  error CTSA_InvalidTradeAmount();
  error CTSA_TradeDataDoesNotMatchOrderHash();
}
