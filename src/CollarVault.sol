// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {IEulerAdapter} from "./interfaces/IEulerAdapter.sol";
import {ISocketBridge} from "./interfaces/ISocketBridge.sol";
import {ISocketConnector} from "./interfaces/ISocketConnector.sol";
import {CollarLZMessages} from "./bridge/CollarLZMessages.sol";
import {ICollarVaultMessenger} from "./interfaces/ICollarVaultMessenger.sol";

interface ILiquidityVault {
  function borrow(uint256 amount) external;
  function repay(uint256 amount) external;
  function writeOff(uint256 amount) external;
  function asset() external view returns (address);
}

contract CollarVault is AccessControl, EIP712, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
  bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
  bytes32 public constant PARAMETER_ROLE = keccak256("PARAMETER_ROLE");
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant QUOTE_SIGNER_ROLE = keccak256("QUOTE_SIGNER_ROLE");
  uint256 public constant YEAR = 365 days;
  uint256 public constant MAX_BPS = 10_000;

  enum LoanState {
    NONE,
    ACTIVE_ZERO_COST,
    ACTIVE_VARIABLE,
    CLOSED
  }

  enum SettlementOutcome {
    PutITM,
    Neutral,
    CallITM
  }

  struct Loan {
    address borrower;
    address collateralAsset;
    uint256 collateralAmount;
    uint256 maturity;
    uint256 putStrike;
    uint256 callStrike;
    uint256 principal;
    uint256 subaccountId;
    LoanState state;
    uint256 startTime;
    uint256 originationFeeApr;
    uint256 variableDebt;
  }

  struct PendingDeposit {
    address borrower;
    address collateralAsset;
    uint256 collateralAmount;
    uint256 maturity;
    bool cancelRequested;
  }

  struct Quote {
    address collateralAsset;
    uint256 collateralAmount;
    uint256 maturity;
    uint256 putStrike;
    uint256 callStrike;
    uint256 borrowAmount;
    uint256 quoteExpiry;
    address borrower;
    uint256 nonce;
  }

  bytes32 public constant QUOTE_TYPEHASH =
    keccak256(
      "Quote(address collateralAsset,uint256 collateralAmount,uint256 maturity,uint256 putStrike,uint256 callStrike,uint256 borrowAmount,uint256 quoteExpiry,address borrower,uint256 nonce)"
    );

  ILiquidityVault public liquidityVault;
  IERC20 public immutable usdc;
  struct SocketBridgeConfig {
    ISocketBridge bridge;
    ISocketConnector connector;
    uint256 msgGasLimit;
    bytes options;
    bytes extraData;
  }

  mapping(address => SocketBridgeConfig) private socketBridgeConfigs;
  IEulerAdapter public eulerAdapter;
  address public l2Recipient;
  address public treasury;
  uint256 public treasuryBps;
  uint256 public originationFeeApr;
  uint256 public deriveSubaccountId;
  uint256 public nextLoanId = 1;

  mapping(uint256 => Loan) public loans;
  mapping(uint256 => PendingDeposit) public pendingDeposits;
  mapping(bytes32 => bool) public usedQuotes;
  mapping(address => bool) public collateralAllowed;
  mapping(address => uint256) public strikeScale;

  ICollarVaultMessenger public lzMessenger;
  mapping(bytes32 => bool) public lzMessageConsumed;

  error CV_ZeroAddress();
  error CV_InvalidAmount();
  error CV_InvalidMaturity();
  error CV_NotMatured();
  error CV_CollateralNotAllowed();
  error CV_StrikeScaleUnset();
  error CV_InvalidBorrowAmount();
  error CV_QuoteExpired();
  error CV_QuoteUsed();
  error CV_InvalidQuoteSigner();
  error CV_InvalidLoanState();
  error CV_InsufficientSettlement();
  error CV_TreasuryBpsTooHigh();
  error CV_NotBorrower();
  error CV_InvalidSubaccount();
  error CV_NotAuthorized();
  error CV_InsufficientBridgeFees();
  error CV_RefundFailed();
  error CV_LZMessengerNotSet();
  error CV_LZMessageNotFound();
  error CV_LZMessageConsumed();
  error CV_LZMessageMismatch();
  error CV_LZMessageRecipientMismatch();
  error CV_PendingDepositNotFound();
  error CV_PendingDepositCancelled();
  error CV_PendingDepositNotCancelled();

  event LoanCreated(
    uint256 indexed loanId,
    address indexed borrower,
    address indexed collateralAsset,
    uint256 collateralAmount,
    uint256 maturity,
    uint256 putStrike,
    uint256 callStrike,
    uint256 principal,
    uint256 subaccountId,
    bytes32 quoteHash
  );
  event LoanSettled(uint256 indexed loanId, SettlementOutcome outcome, uint256 settlementAmount);
  event SettlementShortfall(uint256 indexed loanId, uint256 shortfall);
  event LoanConverted(uint256 indexed loanId, uint256 variableDebt);
  event LoanRolled(uint256 indexed oldLoanId, uint256 indexed newLoanId, uint256 newPrincipal);
  event LoanClosed(uint256 indexed loanId);
  event TreasuryUpdated(address indexed treasury, uint256 bps);
  event OriginationFeeAprUpdated(uint256 feeApr);
  event CollateralConfigUpdated(address indexed asset, bool allowed, uint256 strikeScale);
  event BridgeConfigUpdated(
    address indexed asset,
    address indexed bridge,
    address indexed connector,
    uint256 msgGasLimit,
    bytes options,
    bytes extraData
  );
  event L2RecipientUpdated(address indexed recipient);
  event EulerAdapterUpdated(address indexed adapter);
  event SubaccountUpdated(uint256 subaccountId);
  event QuoteSignerUpdated(address indexed signer, bool allowed);
  event LZMessengerUpdated(address indexed messenger);
  event CollateralDepositRequested(
    uint256 indexed loanId,
    address indexed borrower,
    address indexed collateralAsset,
    uint256 collateralAmount,
    uint256 maturity,
    bytes32 socketMessageId,
    bytes32 lzGuid
  );
  event CollateralCancelRequested(
    uint256 indexed loanId,
    address indexed borrower,
    address indexed collateralAsset,
    uint256 collateralAmount,
    bytes32 lzGuid
  );
  event CollateralDepositReturned(
    uint256 indexed loanId,
    address indexed borrower,
    address indexed collateralAsset,
    uint256 collateralAmount
  );

  constructor(
    address admin,
    ILiquidityVault liquidityVault_,
    address bridgeConfigAdmin_,
    IEulerAdapter eulerAdapter_,
    address l2Recipient_,
    address treasury_
  ) EIP712("CollarVault", "1") {
    if (
      admin == address(0) ||
      address(liquidityVault_) == address(0) ||
      bridgeConfigAdmin_ == address(0) ||
      address(eulerAdapter_) == address(0) ||
      l2Recipient_ == address(0) ||
      treasury_ == address(0)
    ) {
      revert CV_ZeroAddress();
    }

    liquidityVault = liquidityVault_;
    usdc = IERC20(liquidityVault_.asset());
    eulerAdapter = eulerAdapter_;
    l2Recipient = l2Recipient_;
    treasury = treasury_;

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(PARAMETER_ROLE, admin);
    _grantRole(KEEPER_ROLE, admin);
    _grantRole(EXECUTOR_ROLE, admin);
    _grantRole(PAUSER_ROLE, admin);
    _grantRole(PARAMETER_ROLE, bridgeConfigAdmin_);
  }

  /// @notice Create a new zero-cost loan using an EIP-712 signed RFQ quote.
  function createLoan(Quote calldata quote, bytes calldata quoteSig, bytes32 depositGuid, bytes32 tradeGuid)
    external
    nonReentrant
    whenNotPaused
    returns (uint256 loanId)
  {
    _validateQuote(quote, quoteSig, msg.sender);
    if (!collateralAllowed[quote.collateralAsset]) {
      revert CV_CollateralNotAllowed();
    }
    if (quote.maturity <= block.timestamp) {
      revert CV_InvalidMaturity();
    }
    _validateBorrowAmount(quote);
    bytes32 quoteHash;
    (loanId, quoteHash) = _confirmLoanCreation(quote, depositGuid, tradeGuid);
    _openLoan(loanId, quote, quoteHash);
  }

  /// @notice Request collateral deposit to Derive L2 and send a LayerZero deposit intent.
  function requestCollateralDeposit(address collateralAsset, uint256 collateralAmount, uint256 maturity)
    external
    payable
    nonReentrant
    whenNotPaused
    returns (uint256 loanId, bytes32 socketMessageId, bytes32 lzGuid)
  {
    if (!collateralAllowed[collateralAsset]) {
      revert CV_CollateralNotAllowed();
    }
    if (collateralAmount == 0) {
      revert CV_InvalidAmount();
    }
    if (maturity <= block.timestamp) {
      revert CV_InvalidMaturity();
    }
    if (address(lzMessenger) == address(0)) {
      revert CV_LZMessengerNotSet();
    }
    if (deriveSubaccountId == 0) {
      revert CV_InvalidSubaccount();
    }

    loanId = nextLoanId++;
    pendingDeposits[loanId] = PendingDeposit({
      borrower: msg.sender,
      collateralAsset: collateralAsset,
      collateralAmount: collateralAmount,
      maturity: maturity,
      cancelRequested: false
    });

    IERC20(collateralAsset).safeTransferFrom(msg.sender, address(this), collateralAmount);

    SocketBridgeConfig storage config = socketBridgeConfigs[collateralAsset];
    if (address(config.bridge) == address(0) || address(config.connector) == address(0)) {
      revert CV_ZeroAddress();
    }
    socketMessageId = config.connector.getMessageId();

    CollarLZMessages.Message memory message = CollarLZMessages.Message({
      action: CollarLZMessages.Action.DepositIntent,
      loanId: loanId,
      asset: collateralAsset,
      amount: collateralAmount,
      recipient: address(this),
      subaccountId: deriveSubaccountId,
      socketMessageId: socketMessageId,
      secondaryAmount: 0,
      quoteHash: bytes32(0),
      takerNonce: 0
    });

    bytes memory options = lzMessenger.defaultOptions();
    MessagingFee memory lzFee = lzMessenger.quoteMessage(message, options);
    uint256 bridgeFee = estimateBridgeFees(collateralAsset, l2Recipient, collateralAmount);
    uint256 requiredFee = bridgeFee + lzFee.nativeFee;
    if (msg.value < requiredFee) {
      revert CV_InsufficientBridgeFees();
    }

    _bridgeToL2(collateralAsset, collateralAmount, l2Recipient);
    MessagingReceipt memory receipt = lzMessenger.sendMessage{value: lzFee.nativeFee}(message);
    lzGuid = receipt.guid;

    if (msg.value > requiredFee) {
      (bool success, ) = msg.sender.call{value: msg.value - requiredFee}("");
      if (!success) {
        revert CV_RefundFailed();
      }
    }

    emit CollateralDepositRequested(
      loanId,
      msg.sender,
      collateralAsset,
      collateralAmount,
      maturity,
      socketMessageId,
      lzGuid
    );
  }

  /// @notice Request cancellation of a pending collateral deposit before loan creation.
  function requestCancelDeposit(uint256 loanId) external payable nonReentrant whenNotPaused returns (bytes32 lzGuid) {
    PendingDeposit storage pending = pendingDeposits[loanId];
    if (pending.borrower == address(0)) {
      revert CV_PendingDepositNotFound();
    }
    if (pending.borrower != msg.sender) {
      revert CV_NotBorrower();
    }
    if (pending.cancelRequested) {
      revert CV_PendingDepositCancelled();
    }
    if (loans[loanId].state != LoanState.NONE) {
      revert CV_InvalidLoanState();
    }
    if (address(lzMessenger) == address(0)) {
      revert CV_LZMessengerNotSet();
    }
    if (deriveSubaccountId == 0) {
      revert CV_InvalidSubaccount();
    }

    pending.cancelRequested = true;

    CollarLZMessages.Message memory message = CollarLZMessages.Message({
      action: CollarLZMessages.Action.CancelRequest,
      loanId: loanId,
      asset: pending.collateralAsset,
      amount: pending.collateralAmount,
      recipient: address(this),
      subaccountId: deriveSubaccountId,
      socketMessageId: bytes32(0),
      secondaryAmount: 0,
      quoteHash: bytes32(0),
      takerNonce: 0
    });

    bytes memory options = lzMessenger.defaultOptions();
    MessagingFee memory lzFee = lzMessenger.quoteMessage(message, options);
    if (msg.value < lzFee.nativeFee) {
      revert CV_InsufficientBridgeFees();
    }

    MessagingReceipt memory receipt = lzMessenger.sendMessage{value: lzFee.nativeFee}(message);
    lzGuid = receipt.guid;

    if (msg.value > lzFee.nativeFee) {
      (bool success, ) = msg.sender.call{value: msg.value - lzFee.nativeFee}("");
      if (!success) {
        revert CV_RefundFailed();
      }
    }

    emit CollateralCancelRequested(
      loanId,
      msg.sender,
      pending.collateralAsset,
      pending.collateralAmount,
      lzGuid
    );
  }

  /// @notice Finalize a cancelled deposit and return collateral to the borrower.
  function finalizeDepositReturn(uint256 loanId, bytes32 lzGuid) external nonReentrant whenNotPaused {
    CollarLZMessages.Message memory lzMessage = _consumeLZMessage(lzGuid);
    if (lzMessage.action != CollarLZMessages.Action.CollateralReturned || lzMessage.loanId != loanId) {
      revert CV_LZMessageMismatch();
    }
    if (lzMessage.recipient != address(this)) {
      revert CV_LZMessageRecipientMismatch();
    }
    if (deriveSubaccountId != 0 && lzMessage.subaccountId != deriveSubaccountId) {
      revert CV_LZMessageMismatch();
    }

    PendingDeposit memory pending = pendingDeposits[loanId];
    if (pending.borrower == address(0)) {
      revert CV_PendingDepositNotFound();
    }
    if (!pending.cancelRequested) {
      revert CV_PendingDepositNotCancelled();
    }
    if (pending.collateralAsset != lzMessage.asset || pending.collateralAmount != lzMessage.amount) {
      revert CV_LZMessageMismatch();
    }
    if (loans[loanId].state != LoanState.NONE) {
      revert CV_InvalidLoanState();
    }

    delete pendingDeposits[loanId];
    IERC20(pending.collateralAsset).safeTransfer(pending.borrower, pending.collateralAmount);
    emit CollateralDepositReturned(loanId, pending.borrower, pending.collateralAsset, pending.collateralAmount);
  }

  /// @notice Settle a matured loan into one of the three collar outcomes.
  function settleLoan(uint256 loanId, SettlementOutcome outcome, bytes32 lzGuid)
    external
    nonReentrant
    whenNotPaused
    onlyKeeperOrExecutor
  {
    Loan storage loan = loans[loanId];
    if (loan.state != LoanState.ACTIVE_ZERO_COST) {
      revert CV_InvalidLoanState();
    }
    if (block.timestamp < loan.maturity) {
      revert CV_NotMatured();
    }

    CollarLZMessages.Message memory lzMessage = _consumeLZMessage(lzGuid);
    uint256 settlementAmount = 0;

    if (outcome == SettlementOutcome.Neutral) {
      if (
        lzMessage.action != CollarLZMessages.Action.CollateralReturned ||
        lzMessage.loanId != loanId ||
        lzMessage.asset != loan.collateralAsset ||
        lzMessage.amount != loan.collateralAmount
      ) {
        revert CV_LZMessageMismatch();
      }
      if (lzMessage.recipient != address(this)) {
        revert CV_LZMessageRecipientMismatch();
      }
      _convertToVariable(loanId, lzMessage.amount);
      emit LoanSettled(loanId, outcome, settlementAmount);
      return;
    }

    if (
      lzMessage.action != CollarLZMessages.Action.SettlementReport ||
      lzMessage.loanId != loanId ||
      lzMessage.asset != address(usdc)
    ) {
      revert CV_LZMessageMismatch();
    }
    if (lzMessage.recipient != address(this)) {
      revert CV_LZMessageRecipientMismatch();
    }
    settlementAmount = lzMessage.amount;

    uint256 shortfall = 0;
    if (settlementAmount < loan.principal) {
      if (outcome != SettlementOutcome.CallITM) {
        revert CV_InsufficientSettlement();
      }
      shortfall = loan.principal - settlementAmount;
    }

    uint256 repayAmount = settlementAmount > loan.principal ? loan.principal : settlementAmount;
    if (repayAmount > 0) {
      usdc.safeIncreaseAllowance(address(liquidityVault), repayAmount);
      liquidityVault.repay(repayAmount);
    }
    if (shortfall > 0) {
      liquidityVault.writeOff(shortfall);
      emit SettlementShortfall(loanId, shortfall);
    }

    uint256 excess = settlementAmount > loan.principal ? settlementAmount - loan.principal : 0;

    if (excess > 0) {
      if (outcome == SettlementOutcome.PutITM) {
        uint256 treasuryCut = Math.mulDiv(excess, treasuryBps, MAX_BPS);
        uint256 vaultCut = excess - treasuryCut;
        if (treasuryCut > 0) {
          usdc.safeTransfer(treasury, treasuryCut);
        }
        if (vaultCut > 0) {
          usdc.safeTransfer(address(liquidityVault), vaultCut);
        }
      } else if (outcome == SettlementOutcome.CallITM) {
        usdc.safeTransfer(loan.borrower, excess);
      }
    }

    loan.state = LoanState.CLOSED;
    emit LoanSettled(loanId, outcome, settlementAmount);
    emit LoanClosed(loanId);
  }

  /// @notice Convert a neutral-expiry loan into a variable-rate Euler position.
  function convertToVariable(uint256 loanId, bytes32 lzGuid) external nonReentrant whenNotPaused {
    Loan storage loan = loans[loanId];
    if (loan.state != LoanState.ACTIVE_ZERO_COST) {
      revert CV_InvalidLoanState();
    }
    if (block.timestamp < loan.maturity) {
      revert CV_NotMatured();
    }
    if (msg.sender != loan.borrower && !(hasRole(KEEPER_ROLE, msg.sender) || hasRole(EXECUTOR_ROLE, msg.sender))) {
      revert CV_NotAuthorized();
    }

    CollarLZMessages.Message memory lzMessage = _consumeLZMessage(lzGuid);
    if (
      lzMessage.action != CollarLZMessages.Action.CollateralReturned ||
      lzMessage.loanId != loanId ||
      lzMessage.asset != loan.collateralAsset ||
      lzMessage.amount != loan.collateralAmount
    ) {
      revert CV_LZMessageMismatch();
    }
    if (lzMessage.recipient != address(this)) {
      revert CV_LZMessageRecipientMismatch();
    }
    _convertToVariable(loanId, lzMessage.amount);
  }

  /// @notice Repay a variable-rate loan and return collateral to the borrower.
  function repayVariable(uint256 loanId) external nonReentrant {
    Loan storage loan = loans[loanId];
    if (loan.state != LoanState.ACTIVE_VARIABLE) {
      revert CV_InvalidLoanState();
    }
    if (msg.sender != loan.borrower) {
      revert CV_NotBorrower();
    }

    uint256 debt = loan.variableDebt;
    if (debt == 0) {
      revert CV_InvalidAmount();
    }

    usdc.safeTransferFrom(msg.sender, address(this), debt);
    usdc.safeIncreaseAllowance(address(eulerAdapter), debt);
    eulerAdapter.repay(address(usdc), debt, loan.borrower);
    eulerAdapter.withdrawCollateral(loan.collateralAsset, loan.collateralAmount, loan.borrower, loan.borrower);

    loan.state = LoanState.CLOSED;
    emit LoanClosed(loanId);
  }

  /// @notice Roll an active variable loan into a new zero-cost loan.
  function rollLoanToNew(uint256 loanId, Quote calldata quote, bytes calldata quoteSig)
    external
    nonReentrant
    whenNotPaused
    onlyKeeperOrExecutor
    returns (uint256 newLoanId)
  {
    Loan storage loan = loans[loanId];
    if (loan.state != LoanState.ACTIVE_VARIABLE) {
      revert CV_InvalidLoanState();
    }

    _validateQuote(quote, quoteSig, loan.borrower);
    if (quote.collateralAsset != loan.collateralAsset || quote.collateralAmount != loan.collateralAmount) {
      revert CV_InvalidAmount();
    }
    _validateBorrowAmount(quote);

    if (quote.borrowAmount < loan.variableDebt) {
      revert CV_InvalidAmount();
    }

    liquidityVault.borrow(quote.borrowAmount);
    usdc.safeIncreaseAllowance(address(eulerAdapter), loan.variableDebt);
    eulerAdapter.repay(address(usdc), loan.variableDebt, loan.borrower);
    eulerAdapter.withdrawCollateral(loan.collateralAsset, loan.collateralAmount, loan.borrower, address(this));

    _bridgeToL2(loan.collateralAsset, loan.collateralAmount, l2Recipient);

    loan.state = LoanState.CLOSED;
    emit LoanClosed(loanId);

    newLoanId = nextLoanId++;
    loans[newLoanId] = Loan({
      borrower: loan.borrower,
      collateralAsset: quote.collateralAsset,
      collateralAmount: quote.collateralAmount,
      maturity: quote.maturity,
      putStrike: quote.putStrike,
      callStrike: quote.callStrike,
      principal: quote.borrowAmount,
      subaccountId: deriveSubaccountId,
      state: LoanState.ACTIVE_ZERO_COST,
      startTime: block.timestamp,
      originationFeeApr: originationFeeApr,
      variableDebt: 0
    });
    usedQuotes[hashQuote(quote)] = true;

    uint256 payout = quote.borrowAmount - loan.variableDebt;
    if (payout > 0) {
      usdc.safeTransfer(loan.borrower, payout);
    }

    emit LoanRolled(loanId, newLoanId, quote.borrowAmount);
  }

  /// @notice Returns the EIP-712 hash for a quote.
  function hashQuote(Quote calldata quote) public view returns (bytes32) {
    bytes32 structHash =
      keccak256(
        abi.encode(
          QUOTE_TYPEHASH,
          quote.collateralAsset,
          quote.collateralAmount,
          quote.maturity,
          quote.putStrike,
          quote.callStrike,
          quote.borrowAmount,
          quote.quoteExpiry,
          quote.borrower,
          quote.nonce
        )
      );
    return _hashTypedDataV4(structHash);
  }

  /// @notice Return a loan record by id.
  function getLoan(uint256 loanId) external view returns (Loan memory) {
    return loans[loanId];
  }

  /// @notice Calculate the annualized origination fee amount for a loan.
  function calculateOriginationFee(uint256 loanId) external view returns (uint256) {
    Loan storage loan = loans[loanId];
    if (loan.state == LoanState.NONE) {
      revert CV_InvalidLoanState();
    }
    if (loan.maturity <= loan.startTime) {
      return 0;
    }
    uint256 annualFee = Math.mulDiv(loan.principal, loan.originationFeeApr, 1e18);
    uint256 duration = loan.maturity - loan.startTime;
    return Math.mulDiv(annualFee, duration, YEAR);
  }

  /// @notice Update the L2 recipient for bridge transfers.
  function setL2Recipient(address newL2Recipient) external onlyRole(PARAMETER_ROLE) {
    if (newL2Recipient == address(0)) {
      revert CV_ZeroAddress();
    }
    l2Recipient = newL2Recipient;
    emit L2RecipientUpdated(newL2Recipient);
  }

  /// @notice Configure Socket bridge settings for an asset.
  function setSocketBridgeConfig(
    address asset,
    ISocketBridge bridge,
    ISocketConnector connector,
    uint256 msgGasLimit,
    bytes calldata options,
    bytes calldata extraData
  ) external onlyRole(PARAMETER_ROLE) {
    if (asset == address(0) || address(bridge) == address(0) || address(connector) == address(0)) {
      revert CV_ZeroAddress();
    }
    socketBridgeConfigs[asset] = SocketBridgeConfig({
      bridge: bridge,
      connector: connector,
      msgGasLimit: msgGasLimit,
      options: options,
      extraData: extraData
    });
    emit BridgeConfigUpdated(asset, address(bridge), address(connector), msgGasLimit, options, extraData);
  }

  /// @notice Update the Euler adapter.
  function setEulerAdapter(IEulerAdapter newAdapter) external onlyRole(PARAMETER_ROLE) {
    if (address(newAdapter) == address(0)) {
      revert CV_ZeroAddress();
    }
    eulerAdapter = newAdapter;
    emit EulerAdapterUpdated(address(newAdapter));
  }

  /// @notice Update the Derive subaccount id used for action validation.
  function setDeriveSubaccountId(uint256 subaccountId) external onlyRole(PARAMETER_ROLE) {
    if (subaccountId == 0) {
      revert CV_InvalidSubaccount();
    }
    deriveSubaccountId = subaccountId;
    emit SubaccountUpdated(subaccountId);
  }

  /// @notice Update collateral allowlist and strike scale.
  function setCollateralConfig(address asset, bool allowed, uint256 scale) external onlyRole(PARAMETER_ROLE) {
    if (asset == address(0)) {
      revert CV_ZeroAddress();
    }
    collateralAllowed[asset] = allowed;
    strikeScale[asset] = scale;
    emit CollateralConfigUpdated(asset, allowed, scale);
  }

  /// @notice Estimate the Socket bridge fees for a transfer.
  function estimateBridgeFees(address asset, address receiver, uint256 amount) public view returns (uint256) {
    SocketBridgeConfig storage config = socketBridgeConfigs[asset];
    if (address(config.bridge) == address(0) || address(config.connector) == address(0)) {
      revert CV_ZeroAddress();
    }
    bytes memory payload = abi.encode(receiver, amount, bytes32(0), config.extraData);
    return config.connector.getMinFees(config.msgGasLimit, payload.length);
  }

  /// @notice Update treasury configuration for settlement surplus.
  function setTreasuryConfig(address newTreasury, uint256 bps) external onlyRole(PARAMETER_ROLE) {
    if (newTreasury == address(0)) {
      revert CV_ZeroAddress();
    }
    if (bps > MAX_BPS) {
      revert CV_TreasuryBpsTooHigh();
    }
    treasury = newTreasury;
    treasuryBps = bps;
    emit TreasuryUpdated(newTreasury, bps);
  }

  /// @notice Update the annualized origination fee (1e18 precision).
  function setOriginationFeeApr(uint256 feeApr) external onlyRole(PARAMETER_ROLE) {
    originationFeeApr = feeApr;
    emit OriginationFeeAprUpdated(feeApr);
  }

  /// @notice Allow or revoke a quote signer.
  function setQuoteSigner(address signer, bool allowed) external onlyRole(PARAMETER_ROLE) {
    if (signer == address(0)) {
      revert CV_ZeroAddress();
    }
    if (allowed) {
      _grantRole(QUOTE_SIGNER_ROLE, signer);
    } else {
      _revokeRole(QUOTE_SIGNER_ROLE, signer);
    }
    emit QuoteSignerUpdated(signer, allowed);
  }

  /// @notice Update the LayerZero messenger used to validate L2 acknowledgements.
  function setLZMessenger(ICollarVaultMessenger messenger) external onlyRole(PARAMETER_ROLE) {
    if (address(messenger) == address(0)) {
      revert CV_ZeroAddress();
    }
    lzMessenger = messenger;
    emit LZMessengerUpdated(address(messenger));
  }

  /// @notice Pause loan creation and settlement.
  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  /// @notice Unpause loan creation and settlement.
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  function _validateQuote(Quote calldata quote, bytes calldata quoteSig, address expectedBorrower) internal view {
    if (quote.quoteExpiry < block.timestamp) {
      revert CV_QuoteExpired();
    }
    bytes32 quoteHash = hashQuote(quote);
    if (usedQuotes[quoteHash]) {
      revert CV_QuoteUsed();
    }
    address signer = ECDSA.recover(quoteHash, quoteSig);
    if (!hasRole(QUOTE_SIGNER_ROLE, signer)) {
      revert CV_InvalidQuoteSigner();
    }
    if (quote.borrower != address(0) && quote.borrower != expectedBorrower) {
      revert CV_NotAuthorized();
    }
  }

  function _validateBorrowAmount(Quote calldata quote) internal view {
    uint256 scale = strikeScale[quote.collateralAsset];
    if (scale == 0) {
      revert CV_StrikeScaleUnset();
    }
    uint256 expected = Math.mulDiv(quote.collateralAmount, quote.putStrike, scale);
    if (expected != quote.borrowAmount) {
      revert CV_InvalidBorrowAmount();
    }
  }

  function _quoteOriginationFee(Quote calldata quote) internal view returns (uint256) {
    if (originationFeeApr == 0) {
      return 0;
    }
    if (quote.maturity <= block.timestamp) {
      return 0;
    }
    uint256 duration = quote.maturity - block.timestamp;
    uint256 annualFee = Math.mulDiv(quote.borrowAmount, originationFeeApr, 1e18);
    return Math.mulDiv(annualFee, duration, YEAR);
  }

  function _confirmLoanCreation(Quote calldata quote, bytes32 depositGuid, bytes32 tradeGuid)
    internal
    returns (uint256 loanId, bytes32 quoteHash)
  {
    quoteHash = hashQuote(quote);
    if (depositGuid == tradeGuid) {
      revert CV_LZMessageMismatch();
    }
    CollarLZMessages.Message memory depositMessage = _loadLZMessage(depositGuid);
    CollarLZMessages.Message memory tradeMessage = _loadLZMessage(tradeGuid);
    loanId = _validateDepositConfirmed(depositMessage, quote);
    _validateTradeConfirmed(tradeMessage, loanId, quoteHash, quote.nonce);
    _validateOriginationFee(tradeMessage, quote);

    lzMessageConsumed[depositGuid] = true;
    lzMessageConsumed[tradeGuid] = true;
    delete pendingDeposits[loanId];
  }

  function _openLoan(uint256 loanId, Quote calldata quote, bytes32 quoteHash) internal {
    loans[loanId] = Loan({
      borrower: msg.sender,
      collateralAsset: quote.collateralAsset,
      collateralAmount: quote.collateralAmount,
      maturity: quote.maturity,
      putStrike: quote.putStrike,
      callStrike: quote.callStrike,
      principal: quote.borrowAmount,
      subaccountId: deriveSubaccountId,
      state: LoanState.ACTIVE_ZERO_COST,
      startTime: block.timestamp,
      originationFeeApr: originationFeeApr,
      variableDebt: 0
    });
    usedQuotes[quoteHash] = true;

    uint256 feeAmount = _quoteOriginationFee(quote);
    if (feeAmount > 0) {
      uint256 treasuryCut = Math.mulDiv(feeAmount, treasuryBps, MAX_BPS);
      uint256 vaultCut = feeAmount - treasuryCut;
      if (treasuryCut > 0) {
        usdc.safeTransfer(treasury, treasuryCut);
      }
      if (vaultCut > 0) {
        usdc.safeTransfer(address(liquidityVault), vaultCut);
      }
    }

    liquidityVault.borrow(quote.borrowAmount);
    usdc.safeTransfer(msg.sender, quote.borrowAmount);

    emit LoanCreated(
      loanId,
      msg.sender,
      quote.collateralAsset,
      quote.collateralAmount,
      quote.maturity,
      quote.putStrike,
      quote.callStrike,
      quote.borrowAmount,
      deriveSubaccountId,
      quoteHash
    );
  }

  function _convertToVariable(uint256 loanId, uint256 collateralAmount) internal {
    Loan storage loan = loans[loanId];
    if (collateralAmount != loan.collateralAmount) {
      revert CV_InvalidAmount();
    }
    IERC20(loan.collateralAsset).safeIncreaseAllowance(address(eulerAdapter), collateralAmount);
    eulerAdapter.depositCollateral(loan.collateralAsset, collateralAmount, loan.borrower);
    eulerAdapter.borrow(address(usdc), loan.principal, loan.borrower, address(this));
    usdc.safeIncreaseAllowance(address(liquidityVault), loan.principal);
    liquidityVault.repay(loan.principal);
    loan.state = LoanState.ACTIVE_VARIABLE;
    loan.variableDebt = loan.principal;
    emit LoanConverted(loanId, loan.variableDebt);
  }

  function _bridgeToL2(address asset, uint256 amount, address receiver) internal {
    SocketBridgeConfig storage config = socketBridgeConfigs[asset];
    if (address(config.bridge) == address(0) || address(config.connector) == address(0)) {
      revert CV_ZeroAddress();
    }
    uint256 fee = estimateBridgeFees(asset, receiver, amount);
    if (address(this).balance < fee) {
      revert CV_InsufficientBridgeFees();
    }
    IERC20(asset).safeIncreaseAllowance(address(config.bridge), amount);
    config.bridge.bridge{value: fee}(receiver, amount, config.msgGasLimit, address(config.connector), config.extraData, config.options);
  }

  function _loadLZMessage(bytes32 guid) internal view returns (CollarLZMessages.Message memory message) {
    if (address(lzMessenger) == address(0)) {
      revert CV_LZMessengerNotSet();
    }
    if (lzMessageConsumed[guid]) {
      revert CV_LZMessageConsumed();
    }
    (
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
    ) = lzMessenger.receivedMessages(guid);

    if (loanId == 0) {
      revert CV_LZMessageNotFound();
    }

    message = CollarLZMessages.Message({
      action: action,
      loanId: loanId,
      asset: asset,
      amount: amount,
      recipient: recipient,
      subaccountId: subaccountId,
      socketMessageId: socketMessageId,
      secondaryAmount: secondaryAmount,
      quoteHash: quoteHash,
      takerNonce: takerNonce
    });
  }

  function _consumeLZMessage(bytes32 guid) internal returns (CollarLZMessages.Message memory message) {
    message = _loadLZMessage(guid);
    lzMessageConsumed[guid] = true;
  }

  function _validateDepositConfirmed(CollarLZMessages.Message memory lzMessage, Quote calldata quote)
    internal
    view
    returns (uint256 loanId)
  {
    if (
      lzMessage.action != CollarLZMessages.Action.DepositConfirmed ||
      lzMessage.asset != quote.collateralAsset ||
      lzMessage.amount != quote.collateralAmount
    ) {
      revert CV_LZMessageMismatch();
    }
    loanId = lzMessage.loanId;
    if (lzMessage.recipient != address(this)) {
      revert CV_LZMessageRecipientMismatch();
    }
    if (deriveSubaccountId != 0 && lzMessage.subaccountId != deriveSubaccountId) {
      revert CV_LZMessageMismatch();
    }

    PendingDeposit memory pending = pendingDeposits[loanId];
    if (pending.borrower == address(0)) {
      revert CV_PendingDepositNotFound();
    }
    if (pending.cancelRequested) {
      revert CV_PendingDepositCancelled();
    }
    if (pending.borrower != msg.sender) {
      revert CV_NotBorrower();
    }
    if (
      pending.collateralAsset != quote.collateralAsset ||
      pending.collateralAmount != quote.collateralAmount ||
      pending.maturity != quote.maturity
    ) {
      revert CV_LZMessageMismatch();
    }
  }

  function _validateTradeConfirmed(
    CollarLZMessages.Message memory lzMessage,
    uint256 loanId,
    bytes32 quoteHash,
    uint256 takerNonce
  ) internal view {
    if (lzMessage.action != CollarLZMessages.Action.TradeConfirmed || lzMessage.loanId != loanId) {
      revert CV_LZMessageMismatch();
    }
    if (lzMessage.recipient != address(this)) {
      revert CV_LZMessageRecipientMismatch();
    }
    if (deriveSubaccountId != 0 && lzMessage.subaccountId != deriveSubaccountId) {
      revert CV_LZMessageMismatch();
    }
    if (lzMessage.quoteHash != quoteHash || lzMessage.takerNonce != takerNonce) {
      revert CV_LZMessageMismatch();
    }
  }

  function _validateOriginationFee(CollarLZMessages.Message memory lzMessage, Quote calldata quote) internal view {
    uint256 feeAmount = _quoteOriginationFee(quote);
    if (feeAmount == 0) {
      if (lzMessage.amount != 0) {
        revert CV_LZMessageMismatch();
      }
      return;
    }
    if (lzMessage.asset != address(usdc)) {
      revert CV_LZMessageMismatch();
    }
    if (lzMessage.amount != feeAmount) {
      revert CV_LZMessageMismatch();
    }
    if (lzMessage.socketMessageId == bytes32(0)) {
      revert CV_LZMessageMismatch();
    }
  }

  modifier onlyKeeperOrExecutor() {
    if (!(hasRole(KEEPER_ROLE, msg.sender) || hasRole(EXECUTOR_ROLE, msg.sender))) {
      revert CV_NotAuthorized();
    }
    _;
  }

  receive() external payable {}
}
