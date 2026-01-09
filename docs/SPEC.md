# CollarFi Protocol Technical Specification

Version 1.0 - Draft dated 6 Jan 2026

## 1. Overview

CollarFi is a DeFi lending protocol that issues zero-cost, fixed-maturity USDC loans against crypto collateral (major assets supported by Derive, e.g., WBTC, cbBTC, WETH, wstETH). Each loan is hedged by opening a collar on the Derive exchange: the protocol buys a put option to protect the loan principal and sells a call option to collect enough premium to cover the cost of capital, platform fees and (if necessary) the settlement drag. Upon maturity, three outcomes are possible:

1. Put ITM (underwater): the collateral's value is insufficient to repay the principal. The protocol sells the collateral, collects the put payoff and repays lenders.
2. Neutral corridor: both options expire OTM; the borrower's collateral is still worth at least the principal. The loan converts to a variable-rate loan backed by the same collateral in a money-market vault.
3. Call ITM (profit): the collateral appreciates above the call strike. The protocol sells the collateral, pays the call payoff to the option buyer (the market maker) and repays the principal; the borrower receives the upside beyond the call strike.

CollarFi uses Derive's vault architecture and fast bridge to manage the collateral and options on Derive L2 while keeping liquidity and accounting on Ethereum L1 (see Derive official docs: https://docs.derive.xyz/). Liquidity providers deposit USDC into a lending vault; idle funds are deployed into Euler V2 (EVK) for variable yield. Borrowers receive USDC loans; market makers quote call strikes; and an off-chain executor places orders on Derive.

This specification documents the smart contracts, off-chain components and flows necessary to implement CollarFi.

## 2. Entities and Components

| Entity/Component | Description |
| --- | --- |
| Borrower | Permissionless user who provides crypto collateral; receives a zero-cost loan; may roll into a variable-rate loan or refinance into a new collar. |
| Lender | Deposits USDC into an ERC-4626 vault on L1; earns Euler yield and premiums from collars. |
| Vault Contract (L1) | Smart contract controlling collateral, loans and settlement. Inherits from Derive's `BaseOnChainSigningTSA` to support ERC-1271 signatures for Derive orders. Owns a subaccount on Derive L2 (tokenized subaccounts: https://derivexyz.notion.site/Derive-Vaults-27203b51517e80c3aaeac43cc3128a7e). |
| Vault Executor (off-chain) | Authorized signer that prepares and signs orders off-chain, posts them to Derive's API, monitors options positions and triggers settlement. |
| Liquidity Vault (USDC Pool) | ERC-4626 vault storing lender USDC. Integrates with Euler V2 for yield. Tracks available liquidity, active loans and in-flight settlement amounts. |
| Euler Money Market | Lending market where USDC can be lent and borrowed at variable rates. |
| Derive Subaccount | Account on Derive L2 that holds collateral and positions. Owned by the vault contract via ERC-1271. |
| Derive Deposit Module | Module that deposits ERC-20 tokens into a subaccount. Called by the vault via Derive's API. |
| Derive Withdrawal Module | Module that withdraws ERC-20 tokens from a subaccount back to L1. Called via API. |
| Derive Trade Module | Module that matches limit orders and executes trades (options purchases and sales). |
| Derive Fast Bridge | Socket/L2 messaging bridge used for sending USDC and collateral between L1 and L2 quickly. Bypasses the 7-day challenge period of the canonical OP bridge. |
| Market Maker (MM) | External participant quoting call strikes and premiums for the collar. Accepts the call leg of the options trade. |
| Keeper | Service that triggers settlement at maturity and monitors loan state transitions. |

## 3. Collateral and Bridging Flow

### 3.1 Collateral deposit (L1 -> L2)

When a borrower requests a new loan, the vault contract receives collateral (standard, non-rebasing ERC-20 only; use wrapped variants such as wstETH) from the borrower on L1. The vault calls the Socket SuperBridge fast bridge to transfer the collateral to L2. Once it arrives, the vault executor uses the Deposit Module to deposit the tokens into its Derive subaccount. The vault contract records the collateral amount, subaccount ID, and a pending-deposit state until L2 confirmation is complete.

Because RFQ pricing on Derive requires collateral in the subaccount, the loan lifecycle is asynchronous: collateral must be confirmed on L2 before quotes are finalized and the loan is disbursed on L1.

If the RFQ is unfavorable or the borrower cancels before options are opened, the borrower can request a collateral withdrawal. The executor triggers a Withdrawal Module action and bridges the collateral back to L1; the vault releases funds to the borrower once the bridge completes. Withdrawals are disallowed once options have been opened.

### 3.2 Collateral withdrawal (L2 -> L1)

Upon loan maturity or refinance, the vault executor uses the Withdrawal Module to withdraw collateral or USDC from the subaccount. The fast bridge is used to send funds back to the vault on L1. The vault contract waits for the bridged funds before updating liquidity balances.

### 3.3 Deposit/withdraw handlers

For convenience, the vault can implement wrappers that automatically call the deposit or withdrawal modules once the bridge transfer finalizes (see Derive official docs: https://docs.derive.xyz/).

## 4. Derive Vault Architecture

### 4.1 Smart-contract subaccount ownership

Derive uses smart-contract wallets to control subaccounts. Each vault contract inherits `BaseOnChainSigningTSA`, which implements ERC-1271 signature validation. This allows off-chain signed orders to be validated on chain by Derive when settling trades. The vault contract:

- Stores a set of authorized signers and submitters. Only the executor (signer) may sign order actions; only designated submitters may submit orders.
- Implements `isValidSignature(bytes32 hash, bytes signature)` to return the ERC-1271 magic value if the signature was produced by an authorized signer and corresponds to a known action (see Derive official docs: https://docs.derive.xyz/).
- Manages nonces and signed data to prevent replay.

### 4.2 Deposit Module

`DepositModule` allows the vault to deposit ERC-20 tokens into its subaccount. Key points:

- Requires one action per call; the action data encodes a `DepositData` struct specifying the amount, asset and whether to create a new subaccount.
- Transfers the deposit asset from the caller to the vault and approves the Derive asset contract.
- Calls the asset contract's deposit function to credit the subaccount.

### 4.3 Withdrawal Module

`WithdrawalModule` withdraws ERC-20 tokens from a subaccount:

- Requires one action with `WithdrawalData` (asset and amount). The subaccount ID must be non-zero.
- Checks the nonce and calls `IERC20BasedAsset.withdraw` to withdraw the specified amount from the subaccount to the owner.

### 4.4 Trade Module

`TradeModule` executes limit orders:

- The `executeAction` function processes a batch of `VerifiedAction` objects: the taker (the vault) followed by one or more makers (MMs). It verifies order nonces, decodes order data and trade data, updates oracles if needed, and batches asset transfers. It charges taker fees and matches orders via `_fillLimitOrder`.
- `_fillLimitOrder` enforces price slippage limits, ensures the fill does not exceed the maker's limit or the vault's own maximum, updates filled amounts and adds asset transfers for quote and base token flows.

### 4.5 Strategy contracts

Derive provides various strategy contracts (e.g., CCTSA for covered calls, PPTSA for put spreads). Each extends `CollateralManagementTSA`, which includes deposit/withdraw verification and risk parameters. CollarFi can implement its own strategy contract by inheriting from `CollateralManagementTSA` and overriding `_verifyAction` to enforce conditions specific to zero-cost collars (e.g., strike bounds, maturity windows, option limit prices). The strategy contract may also set management and performance fees for the vault (see Derive docs).

## 5. Loan Lifecycle and Scenarios

### 5.1 Zero-cost loan origination

**User input**: Borrower selects collateral asset `Q`, amount and maturity `t` (must match a Derive-defined expiry). They choose a put strike `K_p` (from a tier) and request to borrow USDC amount `D`.

**Collateral deposit (L1 -> L2)**: The vault contract receives the collateral from the borrower, calls the fast bridge to send it to Derive L2 and waits for confirmation. The loan is placed in a pending-deposit state until L2 confirmation and Derive subaccount deposit finalize.

**Subaccount deposit**: After the collateral arrives on L2, the executor calls the Deposit Module with action data (asset: `Q`, amount: `Q`, `managerForNewAccount: true` if new subaccount). This deposits the collateral into the vault's subaccount.

**RFQ (off-chain)**: After collateral is confirmed in the Derive subaccount, the vault executor queries market makers to provide quotes for the call strike `K_c` such that the call premium minus the put premium equals or exceeds the target cost of capital (Euler rate + risk premium and, if needed, settlement drag). Quotes are EIP-712 signed and verified on-chain in `createLoan`. Strike tiers are defined off-chain; the vault does not maintain an on-chain tier list.

**Open collar**: The executor signs and submits a Trade Module action:

- Buy a put with strike `K_p` and maturity `t`.
- Sell a call with strike `K_c` and maturity `t`.

No partial fills are allowed; the orders must be fully matched. The trade must conform to risk limits (e.g., delta within bounds) enforced by the strategy contract. Derive matches the order against market makers and settles the trade, crediting or debiting the subaccount accordingly.

**Loan disbursement**: On L1, after the Derive trade is confirmed, the vault contract withdraws USDC from the liquidity vault (Euler pool) equal to `D` and transfers it to the borrower. It records loan state `ACTIVE_ZERO_COST`, storing a global sequential `loanId`, `Q`, `K_p`, `K_c`, `t`, principal `D` and subaccount ID. Origination fees are annualized (e.g., 0.5% APR) and funded from option premium/settlement proceeds (collection timing TBD).

**Cancellation before trade**: If the RFQ is rejected or expires before the collar is opened, the borrower can cancel and withdraw collateral once it is bridged back from L2. The vault records a cancelled state and prevents subsequent loan creation with that pending deposit.

### 5.2 Maturity settlement

At maturity `t`, the executor (or a keeper) settles the collar position on Derive and triggers one of three outcomes. `S_t` is Derive's official expiry settlement price at maturity.

#### Outcome 1: Put ITM / Underwater (`S_t < K_p`)

- Executor sells the collateral on Derive to USDC and exercises the long put (Derive's settlement mechanism handles option exercise).
- All USDC proceeds (including the put payoff) are withdrawn via the Withdrawal Module. The fast bridge is used to send funds back to L1.
- On L1, the vault contract repays the principal `D` to the lending pool. If proceeds exceed `D`, the excess is distributed between the liquidity vault and protocol treasury according to a governance-configurable split. The loan state becomes `CLOSED` after bridged funds arrive.

#### Outcome 2: Neutral corridor (`K_p <= S_t <= K_c`)

- Both options expire OTM. The collateral remains on Derive and is not encumbered.
- The vault contract bridges the collateral back to L1 via the fast bridge.
- On L1, the collateral is deposited into the Euler V2 market as standard collateral. The borrower may immediately borrow USDC up to a variable rate (subject to Euler's LTV). This variable-rate loan repays the original principal `D`, converting the zero-cost loan to a `VARIABLE` loan.
- The borrower's position remains liquidatable by Euler if the collateral price drops.

#### Outcome 3: Call ITM / Take profit (`S_t > K_c`)

- Executor sells the collateral to USDC and exercises the long put (unused) and settles the short call by paying the call payoff to the market maker.
- After subtracting the call payoff and repaying the principal `D` to the lending pool, any remainder belongs to the borrower. The executor withdraws all USDC and bridges it to L1.
- On L1, the borrower is paid after bridged USDC arrives on L1; the vault contract does not make optimistic payouts. The loan state becomes `CLOSED` after bridged funds arrive.

### 5.3 Variable-rate conversion (neutral corridor)

Since the fast bridge is available for all fund movement, the protocol can remove the dAsset receipts previously proposed for slow bridging. Instead:

- Collateral release: Upon neutral maturity, the collateral is unencumbered on Derive. The executor uses the Withdrawal Module to withdraw the collateral to L2 and bridges it back to L1.
- Euler deposit: The collateral is deposited into a standard Euler V2 market on L1. The borrower borrows USDC up to the maximum LTV permitted by Euler. The borrowed USDC repays the zero-cost loan principal.
- Accounting: The loan state changes from `ACTIVE_ZERO_COST` to `ACTIVE_VARIABLE`. Interest accrues at the Euler variable rate. When the borrower repays, the collateral is returned.

### 5.4 Rolling a variable loan into a new collar

Borrowers may roll an active variable-rate loan into a new zero-cost loan:

1. Repay variable debt: The protocol uses new loan proceeds to repay the borrower's outstanding variable debt in Euler. This action releases the collateral.
2. Bridge collateral to L2: The released collateral is fast-bridged to Derive and deposited into the vault's subaccount.
3. Open new collar: The executor runs another RFQ, opens a new collar with chosen strikes and maturity, and records a new `loanId`. The difference between the new principal and the repaid variable debt is paid to the borrower. The previous loan entry is closed.

## 6. Smart Contracts and Interactions

### 6.1 Vault contract (L1)

Inherits `BaseOnChainSigningTSA`. Stores signers and submitters, manages nonces and signed actions (see Derive official docs: https://docs.derive.xyz/).

All dependent smart contracts should be placed under the `lib/` folder.

Owns the Derive subaccount and calls deposit/withdraw modules via off-chain actions. Maintains loan records, collateral amounts and maturity schedules.

Provides functions:

- `requestCollateralDeposit(collateralAsset, collateralAmount, maturity)` - permissionless; receives collateral, calls the bridge, and records a pending deposit awaiting L2 confirmation.
- `createLoan(collateralAsset, collateralAmount, maturity, Kp, borrowAmount)` - permissionless; only after L2 confirmation and RFQ; triggers trade actions via executor and disburses the loan.
- `cancelPendingDeposit(depositId)` - permissionless for the borrower while no options are opened; triggers L2 withdrawal and returns collateral after bridge finality.
- `settleLoan(loanId)` - restricted to keeper/executor roles; closes positions and initiates bridging of proceeds.
- `convertToVariable(loanId)` - restricted to keeper/executor roles; bridges collateral back and interacts with Euler.
- `rollLoanToNew(loanId, newKp, newMaturity)` - restricted to keeper/executor roles; repays variable debt and opens a new collar.

Exposes events for state changes (`LoanCreated`, `LoanSettled`, `LoanRolled`, etc.).

### 6.2 Off-chain executor

Runs a secure service that:

- Generates `SignedAction` objects (deposit, trade, withdraw) and signs them with the vault's authorized signer.
- Posts actions to Derive's API (e.g., `/post_private-order` for trades).
- Submits trades via the Trade Module, matching orders with market makers.
- Monitors oracle prices and maturity times; triggers settlement via the vault contract.
- Monitors pending collateral deposits, confirms L2 subaccount credit before RFQ/trade, and handles cancellation withdrawals.
- Interacts with the fast bridge and deposit/withdraw handlers.

### 6.3 Liquidity vault (USDC pool)

Implements ERC-4626 for lenders. Idle USDC is deposited into Euler V2; variable-rate earnings accrue to lenders.

Tracks three balances: `availableLiquidity`, `activeLoans` and `inFlight` (though in-flight may be zero with fast bridge). Lenders can withdraw even if `inFlight` > 0; accounting treatment is specified in the clarifications section.

Exposes functions `borrow(uint256 amount)` and `repay(uint256 amount)` for the vault contract.

May cap the total notional per maturity bucket and total in-flight settlement to manage risk.

### 6.4 Euler integration

On neutral maturity, the vault contract deposits collateral into Euler V2 as collateral. It then borrows USDC; interest accrues at the variable rate.

When the borrower repays, the vault contract returns the collateral to the borrower and repays the Euler debt.

### 6.5 Bridging contracts

The vault must integrate with the Socket SuperBridge fast bridge on L1. Daily limits and connector fees apply (see Derive/Socket docs).

Events on the bridge are monitored by the deposit/withdraw handlers to trigger module calls on L2.

### 6.6 Pricing and RFQ service

A separate off-chain module handles quoting. It queries MMs for call strike quotes given the borrower's requested principal and put strike. It ensures the call premium minus put premium meets the target cost of capital (Euler rate + risk premium). Settlement drag is negligible due to fast bridging.

The RFQ module produces EIP-712 signed quotes that are verified on-chain in `createLoan`.

### 6.7 Keeper and monitoring

A keeper service must monitor block timestamps and call `settleLoan` once a loan's maturity is reached. It ensures the Derive position is closed and bridging initiated. Settlement uses Derive's official expiry settlement price at maturity (`S_t`).

Monitors for situations such as the bridge being down or fast withdrawal limits reached; in such cases it may delay new originations or enforce variable-rate conversion.

## 7. Security and Risk Controls

- Signature authenticity: Only authorized signers can sign Derive actions; signatures are validated via ERC-1271 in the vault (see Derive official docs: https://docs.derive.xyz/).
- Replay protection: Nonces are stored per action; signed data cannot be reused or submitted by unauthorized parties.
- Market risk parameters: The strategy contract may set strike ranges, time-to-expiry bounds, and slippage tolerances. The vault must ensure the collateral covers all short calls and that no deposit/withdraw actions leave the subaccount insolvent.
- Bridge limits: The fast bridge has daily deposit/withdraw limits (see Derive official docs: https://docs.derive.xyz/). The vault should track cumulative amounts and throttle operations if limits are approached.
- Liquidation risk: Variable-rate loans on Euler are subject to liquidation. The protocol relies on Euler's liquidation mechanisms rather than triggering forced sales.
- Withdrawal race conditions: Because bridging is asynchronous, ensure that bridging calls are idempotent and that funds are not double-counted.
- Oracle reliability: Use multiple price feeds or Derive's TWAP to determine settlement prices. Validate oracle data in the off-chain executor.
- Role-based parameter changes: Strike bounds, slippage tolerances, market allowlists and other risk parameters are adjustable by a role controlled by a multisig; governance modules may replace this role later.
- Emergency controls: The protocol supports emergency controls to pause new loans and settlement.

## 8. Deployment and Configuration

- Deploy the vault contract inheriting from `BaseOnChainSigningTSA`. Configure authorized signers/submitters, derivative asset addresses and Derive subaccount.
- Deploy the liquidity vault (ERC-4626), integrate with Euler V2 and configure deposit/withdraw functions for the vault contract.
- Set up the fast bridge by referencing the Derive bridge contract addresses for each asset and granting necessary approvals.
- Deploy the strategy contract if risk checks or fee schedules are custom. Otherwise, reuse Derive's existing modules.
- Initialize the vault executor with credentials for Derive's API and keys for signing actions.
- Configure keeper services to monitor maturities, bridging events and Euler liquidations.
- Establish RFQ feeds with market makers to obtain call strike quotes and option premiums.
- Configure governance/owner roles as a multisig; later upgrades to a governance module are permitted for parameter updates.

## 9. Clarifications and TBDs

The following items are not yet specified and require clarification before implementation:

- Trade verification: what L1 proof, if any, is required that the Derive trade executed before loan disbursement or settlement (bridge arrival only vs L2 attestation vs off-chain attestation).
- In-flight accounting: how `inFlight` balances affect liquidity vault share price and withdrawal limits.
- On-chain bounds: whether any on-chain strike/maturity bounds or whitelists should be enforced, or if these are executor-only checks.
- Maturity enforcement: whether Derive-defined maturities are enforced on-chain or only by the executor.
- Origination fee timing: fee is annualized and funded from option premium/settlement proceeds, but the exact timing of collection (at origination vs at settlement) is TBD.

## 10. Conclusion

By leveraging Derive's vault architecture and fast bridge, CollarFi can implement a non-custodial lending protocol that hedges collateralized loans with zero-cost collars. A smart contract on L1 owns a Derive subaccount, places options trades via an off-chain executor and uses rapid bridging to move collateral and settlements between chains. When options expire neutrally, the collateral is bridged back and deposited into Euler V2 to continue earning yield via a variable-rate loan. Rolling to new collars or converting between loan types is straightforward and transparent. Careful configuration of signers, nonces, bridge limits and risk parameters ensures solvency and security for lenders and borrowers alike.
