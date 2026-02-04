import { createPublicClient, createWalletClient, http, type Hex } from "viem";
import { mnemonicToAccount, privateKeyToAccount } from "viem/accounts";

export function makeClients(
  rpcUrl: string,
  opts:
    | { privateKey: Hex }
    | { mnemonic: string; addressIndex: number }
) {
  const account =
    "privateKey" in opts
      ? privateKeyToAccount(opts.privateKey)
      : mnemonicToAccount(opts.mnemonic, { addressIndex: opts.addressIndex });

  const transport = http(rpcUrl);
  const publicClient = createPublicClient({ transport });
  const walletClient = createWalletClient({ account, transport });
  return { account, publicClient, walletClient };
}
