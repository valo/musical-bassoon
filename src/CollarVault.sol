// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMatching} from "v2-matching/src/interfaces/IMatching.sol";

import {IEulerAdapter} from "./interfaces/IEulerAdapter.sol";
import {ISocketBridge} from "./interfaces/ISocketBridge.sol";
import {ISocketConnector} from "./interfaces/ISocketConnector.sol";

interface ILiquidityVault {
  function borrow(uint256 amount) external;
  function repay(uint256 amount) external;
  function asset() external view returns (address);
}

/// TODO: Spec calls for BaseOnChainSigningTSA inheritance; confirm if a proxy-based TSA should replace this signer module.
contract CollarVault is AccessControl, EIP712, IERC1271, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
  bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
  bytes32 public constant PARAMETER_ROLE = keccak256("PARAMETER_ROLE");
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant QUOTE_SIGNER_ROLE = keccak256("QUOTE_SIGNER_ROLE");
  bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
  bytes32 public constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");

  bytes4 internal constant MAGICVALUE = 0x1626ba7e;
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
  IMatching public matching;
  address public l2Recipient;
  address public treasury;
  uint256 public treasuryBps;
  uint256 public originationFeeApr;
  uint256 public deriveSubaccountId;
  uint256 public nextLoanId = 1;

  mapping(uint256 => Loan) public loans;
  mapping(bytes32 => bool) public usedQuotes;
  mapping(address => bool) public collateralAllowed;
  mapping(address => uint256) public strikeScale;

  mapping(bytes32 => bool) public signedData;
  bool public signaturesDisabled;

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
  error CV_InvalidSignature();
  error CV_InvalidLoanState();
  error CV_InsufficientSettlement();
  error CV_TreasuryBpsTooHigh();
  error CV_NotBorrower();
  error CV_InvalidSubaccount();
  error CV_ActionExpired();
  error CV_MatchingNotSet();
  error CV_NotAuthorized();
  error CV_InsufficientBridgeFees();

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
  event MatchingUpdated(address indexed matching);
  event SubaccountUpdated(uint256 subaccountId);
  event QuoteSignerUpdated(address indexed signer, bool allowed);
  event SignerUpdated(address indexed signer, bool allowed);
  event SubmitterUpdated(address indexed submitter, bool allowed);
  event SignaturesDisabledUpdated(bool disabled);
  event ActionSigned(address indexed signer, bytes32 indexed hash, IMatching.Action action);
  event SignatureRevoked(address indexed signer, bytes32 indexed hash);

  constructor(
    address admin,
    ILiquidityVault liquidityVault_,
    address bridgeConfigAdmin_,
    IEulerAdapter eulerAdapter_,
    IMatching matching_,
    address l2Recipient_,
    address treasury_
  ) EIP712("CollarVault", "1") {
    if (
      admin == address(0) ||
      address(liquidityVault_) == address(0) ||
      bridgeConfigAdmin_ == address(0) ||
      address(eulerAdapter_) == address(0) ||
      address(matching_) == address(0) ||
      l2Recipient_ == address(0) ||
      treasury_ == address(0)
    ) {
      revert CV_ZeroAddress();
    }

    liquidityVault = liquidityVault_;
    usdc = IERC20(liquidityVault_.asset());
    eulerAdapter = eulerAdapter_;
    matching = matching_;
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
  function createLoan(Quote calldata quote, bytes calldata quoteSig)
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

    loanId = nextLoanId++;
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
    usedQuotes[hashQuote(quote)] = true;

    IERC20(quote.collateralAsset).safeTransferFrom(msg.sender, address(this), quote.collateralAmount);
    _bridgeToL2(quote.collateralAsset, quote.collateralAmount, l2Recipient);

    // TODO: Verify Derive trade execution before disbursing when trade verification is specified.
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
      hashQuote(quote)
    );
  }

  /// @notice Settle a matured loan into one of the three collar outcomes.
  function settleLoan(
    uint256 loanId,
    SettlementOutcome outcome,
    uint256 settlementAmount,
    uint256 collateralAmount
  ) external nonReentrant whenNotPaused onlyKeeperOrExecutor {
    Loan storage loan = loans[loanId];
    if (loan.state != LoanState.ACTIVE_ZERO_COST) {
      revert CV_InvalidLoanState();
    }
    if (block.timestamp < loan.maturity) {
      revert CV_NotMatured();
    }

    if (outcome == SettlementOutcome.Neutral) {
      _convertToVariable(loanId, collateralAmount);
      emit LoanSettled(loanId, outcome, settlementAmount);
      return;
    }

    if (settlementAmount < loan.principal) {
      revert CV_InsufficientSettlement();
    }

    // TODO: Clarify origination fee collection timing and deduct accordingly.
    usdc.safeIncreaseAllowance(address(liquidityVault), loan.principal);
    liquidityVault.repay(loan.principal);
    uint256 excess = settlementAmount - loan.principal;

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
  function convertToVariable(uint256 loanId, uint256 collateralAmount)
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
    _convertToVariable(loanId, collateralAmount);
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

  /// @notice Returns the EIP-712 hash for a Derive action.
  function getActionTypedDataHash(IMatching.Action memory action) public view returns (bytes32) {
    if (address(matching) == address(0)) {
      revert CV_MatchingNotSet();
    }
    return MessageHashUtils.toTypedDataHash(matching.domainSeparator(), matching.getActionHash(action));
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

  /// @notice Record an action hash as signed by an authorized signer.
  function signActionData(IMatching.Action memory action, bytes memory extraData) external onlyRole(SIGNER_ROLE) {
    _signActionData(action, extraData);
  }

  /// @notice Record an action hash via a submitter using a signer signature.
  function signActionViaPermit(IMatching.Action memory action, bytes memory extraData, bytes memory signerSig)
    external
    onlyRole(SUBMITTER_ROLE)
  {
    bytes32 hash = getActionTypedDataHash(action);
    address recovered = ECDSA.recover(hash, signerSig);
    if (!hasRole(SIGNER_ROLE, recovered)) {
      revert CV_InvalidSignature();
    }
    _signActionData(action, extraData);
  }

  /// @notice Revoke a previously signed action.
  function revokeActionSignature(IMatching.Action memory action) external onlyRole(SIGNER_ROLE) {
    _revokeSignature(getActionTypedDataHash(action));
  }

  /// @notice Revoke a signature by hash.
  function revokeSignature(bytes32 typedDataHash) external onlyRole(SIGNER_ROLE) {
    _revokeSignature(typedDataHash);
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

  /// @notice Update the Derive matching contract reference.
  function setMatching(IMatching newMatching) external onlyRole(PARAMETER_ROLE) {
    if (address(newMatching) == address(0)) {
      revert CV_ZeroAddress();
    }
    matching = newMatching;
    emit MatchingUpdated(address(newMatching));
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

  /// @notice Allow or revoke a signer for Derive actions.
  function setSigner(address signer, bool allowed) external onlyRole(PARAMETER_ROLE) {
    if (signer == address(0)) {
      revert CV_ZeroAddress();
    }
    if (allowed) {
      _grantRole(SIGNER_ROLE, signer);
    } else {
      _revokeRole(SIGNER_ROLE, signer);
    }
    emit SignerUpdated(signer, allowed);
  }

  /// @notice Allow or revoke a submitter for Derive actions.
  function setSubmitter(address submitter, bool allowed) external onlyRole(PARAMETER_ROLE) {
    if (submitter == address(0)) {
      revert CV_ZeroAddress();
    }
    if (allowed) {
      _grantRole(SUBMITTER_ROLE, submitter);
    } else {
      _revokeRole(SUBMITTER_ROLE, submitter);
    }
    emit SubmitterUpdated(submitter, allowed);
  }

  /// @notice Disable or enable ERC-1271 signature validation.
  function setSignaturesDisabled(bool disabled) external onlyRole(PARAMETER_ROLE) {
    signaturesDisabled = disabled;
    emit SignaturesDisabledUpdated(disabled);
  }

  /// @notice Pause loan creation and settlement.
  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  /// @notice Unpause loan creation and settlement.
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  /// @notice ERC-1271 signature validation.
  function isValidSignature(bytes32 hash, bytes memory) external view override returns (bytes4) {
    if (!signaturesDisabled && signedData[hash]) {
      return MAGICVALUE;
    }
    return bytes4(0);
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

  function _signActionData(IMatching.Action memory action, bytes memory extraData) internal {
    bytes32 hash = getActionTypedDataHash(action);
    if (action.signer != address(this)) {
      revert CV_InvalidSignature();
    }
    _verifyAction(action, hash, extraData);
    signedData[hash] = true;
    emit ActionSigned(action.signer, hash, action);
  }

  function _revokeSignature(bytes32 hash) internal {
    signedData[hash] = false;
    emit SignatureRevoked(msg.sender, hash);
  }

  function _verifyAction(IMatching.Action memory action, bytes32, bytes memory) internal view {
    if (deriveSubaccountId == 0 || action.subaccountId != deriveSubaccountId) {
      revert CV_InvalidSubaccount();
    }
    if (action.expiry < block.timestamp) {
      revert CV_ActionExpired();
    }
    // TODO: Add strategy-specific checks once strike bounds and risk limits are specified.
  }

  modifier onlyKeeperOrExecutor() {
    if (!(hasRole(KEEPER_ROLE, msg.sender) || hasRole(EXECUTOR_ROLE, msg.sender))) {
      revert CV_NotAuthorized();
    }
    _;
  }

  receive() external payable {}
}
