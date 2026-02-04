# Keeper devnet (forks)

You chose:
- forks (`anvil --fork-url ...`)
- L2 target: Optimism
- no raw private keys in `.env` (use anvil default accounts)

## Prereqs

- Foundry installed in WSL: <https://book.getfoundry.sh/getting-started/installation>
- RPC endpoints:
  - Ethereum mainnet RPC (for L1 fork)
  - Optimism mainnet RPC (for L2 fork)

## 1) Start forks

In two terminals:

```bash
# L1 fork
anvil --fork-url "$MAINNET_RPC_URL" --port 8545

# L2 fork (Optimism)
anvil --fork-url "$OP_RPC_URL" --port 9545
```

## 2) Deploy

### L1 deploy (Vault + LZ Messenger)

Create a `.env` for forge scripts (NOT the keeper one):

```bash
export RPC_URL=http://127.0.0.1:8545
export ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export VAULT_OWNER=$ADMIN
export BRIDGE_CONFIG_ADMIN=$ADMIN

# These are *real addresses* on mainnet/op, or mocks you deploy.
# You must provide them.
export LIQUIDITY_VAULT=0x...
export EULER_ADAPTER=0x...
export PERMIT2=0x...
export TREASURY=$ADMIN
export L2_RECIPIENT=0x...

# LayerZero
export LZ_ENDPOINT=0x...
export L2_EID=30111   # example only; set correct eid

export OUTPUT_JSON=keeper/out/l1-addresses.json

forge script script/DeployL1.s.sol:DeployL1 \
  --rpc-url "$RPC_URL" \
  --broadcast
```

### L2 deploy (TSA Receiver)

```bash
export RPC_URL=http://127.0.0.1:9545
export ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

export LZ_ENDPOINT=0x...
export SOCKET_TRACKER=0x...
export TSA=0x...

export L1_EID=30101   # example only; set correct eid
export L1_MESSENGER=$(jq -r .addrs.l1Messenger keeper/out/l1-addresses.json)
export L1_VAULT=$(jq -r .addrs.l1Vault keeper/out/l1-addresses.json)

export OUTPUT_JSON=keeper/out/l2-addresses.json

forge script script/DeployL2.s.sol:DeployL2 \
  --rpc-url "$RPC_URL" \
  --broadcast
```

## 3) Run the keeper

```bash
cd keeper
cp .env.example .env

# fill in:
# - L1/L2 RPC URLs
# - L1_COLLAR_VAULT / L1_LZ_MESSENGER / L2_TSA_RECEIVER (from the deploy JSONs)

pnpm dev
```
