# Security review and verification scope

## Design review

The local review used the supplied pinned Ethereum security checklist and the
protected custom-token test definitions. The deployed token is the unmodified
OpenZeppelin 5.0.2 ERC-20 implementation with a constructor-only fixed mint.
The separate application has no minting, token-administration, delegatecall,
upgrade, arbitrary-call, or balance-seizure path.

The application constructor receives the owner explicitly and does not call the
token or allocate tokens. The token address is immutable. The result reporter
starts unconfigured and is owner-settable with an event. Existing race terms
cannot change after creation. Token balances, allowances, and transfer hooks
are not affected by application ownership or reporter decisions.

Escrow conservation is maintained with per-race and global liabilities. ETH
payments and token transfers use checks-effects-interactions and OpenZeppelin's
reentrancy guard. Claims authorize the position by `msg.sender`; a caller can
redirect only its own claim. SafeERC20 detects failed token transfers, exact
received funding is checked, and payment failures roll back all accounting.
Final rounding remainders stay with participants, and no admin can sweep an
unclaimed award. The supported reward asset is this launch's HAMSTER, not an
arbitrary rebasing or fee-on-transfer token.

The oracle model is explicitly trusted reporting of external events. No
timestamp, block hash, user seed, or DEX price decides valuable outcomes.
Reporter malice and multiple-address reward farming are trust/economic risks
described in the README. Loss rewards are capped at `R * L / T`, so a bettor
covering every hamster cannot capture the whole budget; the winning side's
share returns to the sponsor after `resolveBy`, and unclaimed loss rewards
stay reserved for losers. Timeout cancellation addresses unavailable reporters,
not dishonest reports. There is no external randomness or price feed to mock
or misrepresent as production verification.

## Checks performed

- `forge build` using the pinned Solidity 0.8.26 configuration.
- `forge test` with the assignment's required fuzz seed, including unit tests,
  512-run fuzz tests, and a 128-run / 64-depth stateful invariant suite.
- `forge fmt --check` after formatting project sources and tests.
- Offline build/test verification using the vendored dependencies.
- Manual inspection of authorization, immutable terms, terminal state handling,
  rounding, token/native transfer failure, and cross-race escrow accounting.

The stateful suite checks conservation after arbitrary interleavings and drains
all remaining claims/refunds after each sequence. Adversarial tests exercise
reentrant and rejecting recipients, failed HAMSTER payments, failed/short
funding, deadline boundaries, and rollback of claims and allowances.

Foundry's lint warnings about timestamps apply to intended deadline checks,
not randomness. Exact balance-difference equality deliberately rejects short
funding. Native transfers deliberately go to the authenticated claimant's
chosen recipient after accounting updates, behind `nonReentrant`.
The recipient helper rejects zero and the application address. These patterns
were inspected in context rather than globally disabling lint rules.

## Limits and release work

Slither and Mythril were not run. No live network, factory, wallet, oracle,
Uniswap pool, or explorer was accessed to execute a deployment or transaction.
The supplied protected tests require the verifier's separate network harness;
their full integration assertions were read but not executed locally. The
local factory-flow test checks exact distribution/return transfers without
simulating the Uniswap liquidity and swap engine.

Before accepting public funds, an independent contributor should review the
contracts and the operational reporting arrangement. The launch process should
verify the deployed bytecode, token supply, application token address, owner,
and reporter configuration, and publish verified sources and race rules.
This repository contains implementation and local checks, not an independent
audit attestation or proof that an external reporter will be honest.
