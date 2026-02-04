export type Hex32 = `0x${string}`;

export type LZAction =
  | "DepositIntent"
  | "CancelRequest"
  | "ReturnRequest"
  | "SettlementReport"
  | "DepositConfirmed"
  | "CollateralReturned"
  | "TradeConfirmed";

export interface LZMessage {
  guid: Hex32;
  action: LZAction;
  loanId: bigint;
  asset: `0x${string}`;
  amount: bigint;
  recipient: `0x${string}`;
  subaccountId: bigint;
  socketMessageId: Hex32;
  secondaryAmount: bigint;
  quoteHash: Hex32;
  takerNonce: bigint;
}

export interface PendingL2Guid {
  guid: Hex32;
  loanId: bigint;
  action: LZAction;
}

export interface KeeperState {
  l1Block: bigint;
  l2Block: bigint;
  // For each loanId, best known guids
  depositConfirmedGuidByLoan: Map<bigint, Hex32>;
  tradeConfirmedGuidByLoan: Map<bigint, Hex32>;
  collateralReturnedGuidByLoan: Map<bigint, Hex32>;
  settlementReportGuidByLoan: Map<bigint, Hex32>;
  // L2 received messages to handle
  l2UnhandledGuids: Set<Hex32>;
}

export function newState(l1Start: bigint, l2Start: bigint): KeeperState {
  return {
    l1Block: l1Start,
    l2Block: l2Start,
    depositConfirmedGuidByLoan: new Map(),
    tradeConfirmedGuidByLoan: new Map(),
    collateralReturnedGuidByLoan: new Map(),
    settlementReportGuidByLoan: new Map(),
    l2UnhandledGuids: new Set()
  };
}
