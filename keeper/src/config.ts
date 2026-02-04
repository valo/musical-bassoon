import { z } from "zod";
import "dotenv/config";

const Env = z.object({
  L1_RPC_URL: z.string().url(),
  L2_RPC_URL: z.string().url(),
  L1_KEEPER_PK: z.string().min(10),
  L2_KEEPER_PK: z.string().min(10),
  L1_COLLAR_VAULT: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  L1_LZ_MESSENGER: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  L2_TSA_RECEIVER: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  L1_START_BLOCK: z.coerce.bigint().default(0n),
  L2_START_BLOCK: z.coerce.bigint().default(0n),
  POLL_MS: z.coerce.number().int().positive().default(3000),
  L2_MAX_VALUE_WEI: z.coerce.bigint().default(0n)
});

export type KeeperConfig = z.infer<typeof Env>;

export function loadConfig(): KeeperConfig {
  const parsed = Env.safeParse(process.env);
  if (!parsed.success) {
    // zod error is pretty readable; surface it and fail hard.
    console.error(parsed.error.flatten().fieldErrors);
    throw new Error("Invalid keeper env config");
  }
  return parsed.data;
}
