## 🔒 Core Guidelines for Agents

Agents contributing to this repository MUST follow these principles:

### 1. **Specification-driven development**
- The canonical source of truth for protocol behavior is `docs/SPEC.md`.
- Agents must not infer missing behavior; follow exactly what is written.
- If something in the SPEC is unclear:
  - add a TODO / comment requesting clarification rather than modifying semantics.

---

### 2. **Security first**
Generated Solidity code MUST:
- avoid common security pitfalls (reentrancy, improper external calls, unbounded loops, unsafe ERC20 transfers, timestamp manipulation, integer overflows).
- use:
  - `SafeERC20`
  - checks-effects-interactions pattern
  - custom errors instead of revert strings
  - access control only when needed and never leave dangerous owner powers
- ensure critical functions such as settlement cannot be called twice
- enforce strict invariants across loan lifecycle

Agents SHOULD:
- surface security concerns in comments when uncertainty arises
- avoid novel or exotic patterns without explicit instruction

---

### 3. **Thorough testing requirements**

All Solidity code MUST be accompanied by good tests.

Agents MUST:
- write Foundry tests for every contract and public flow
- prefer **property-based / fuzzing tests** whenever meaningful
- stress test settlement boundary conditions
- include tests for:
  - expiry boundary edge cases
  - extreme BTC price scenarios (0, huge values)
  - rounding and precision issues
  - invalid RFQ signatures and expired quotes
  - replay protection
  - no reentrancy or double settlement

Goal:  
**minimize the chance that untested behavior exists.**

---

### 4. **Readable and maintainable Solidity**

Agents MUST produce clean, consistent code:
- clear naming (functions, variables, events)
- minimal business logic inside constructors
- prefer small, composable functions
- provide NatSpec for external/public functions
- clear events for origination + settlement flows

Avoid unnecessary complexity.  

When implementing payoff logic, clarity > micro-optimizations.

---

### 5. **Deterministic behavior**

Agents must ensure:
- settlements are deterministic
- no nondeterministic randomness sources
- oracle reads happen only where specified

---

### 6. **Upgradability assumptions**

Unless explicitly specified in `docs/SPEC.md`, agents should:
- assume contracts are **non-upgradeable**
- avoid proxy patterns
- avoid owner-controlled escape hatches

---

## 🚫 Agents MUST NOT

- change settlement or payoff semantics
- add liquidation/margin logic
- assume the protocol interacts with Deribit or other CeFi systems
- introduce new economic assumptions
- rely on off-chain guarantees in smart contract code

Those elements belong strictly to `docs/SPEC.md`.

---

## 🧠 When agents are uncertain

Agents should:
1. Preserve existing semantics.
2. Add comments requesting clarification.
3. Avoid making unapproved assumptions.

---

## 📍 Final reminder

The job of the agent in this repo is to:

- **translate the specification in `docs/SPEC.md` into safe, deterministic, well-tested Solidity**,  
- **not to invent economic behavior** or extend the system beyond the documented design.

Following these guidelines ensures that generated code remains:
- safe
- auditable
- spec-aligned
- production-ready for deployment on EVM chains.

