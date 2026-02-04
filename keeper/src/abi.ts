import fs from "node:fs";
import path from "node:path";

export type Abi = any[];

function repoRoot(): string {
  // keeper/src -> keeper -> collar.fi
  return path.resolve(import.meta.dirname, "..", "..");
}

function loadOutAbi(contractFile: string, contractName: string): Abi {
  // Foundry output layout: out/<file.sol>/<Contract>.json
  const p = path.join(repoRoot(), "out", contractFile, `${contractName}.json`);
  const raw = fs.readFileSync(p, "utf8");
  const j = JSON.parse(raw);
  if (!Array.isArray(j.abi)) {
    throw new Error(`ABI not found in ${p}`);
  }
  return j.abi;
}

export const CollarVaultAbi = loadOutAbi("CollarVault.sol", "CollarVault");
export const CollarVaultMessengerAbi = loadOutAbi("CollarVaultMessenger.sol", "CollarVaultMessenger");
export const CollarTSAReceiverAbi = loadOutAbi("CollarTSAReceiver.sol", "CollarTSAReceiver");
