# HAMSTER

HAMSTER (`HAMSTER`) is an ERC-20 with **1,000,000,000 tokens and 18 decimals**.
`HamsterToken` mints exactly **1,000,000,000,000,000,000,000,000,000 minor units**
once, to its constructor caller. `HamsterRaces` implements “bet on hamster,
lose to earn $HAMSTER” using ETH bets and separately funded HAMSTER rewards.

## Contracts and assumptions

| Contract | Purpose | Constructor arguments |
| --- | --- | --- |
| `HamsterToken` | Fixed supply HAMSTER token | None |
| `HamsterRaces` | Race betting, loss rewards, and refunds | `IERC20 hamster_`, `address owner_` |

The token has standard OpenZeppelin ERC-20 transfers, approvals, and allowances.
Transfers deliver the exact amount, including transfers to and from contracts.
There is no token owner, subsequent mint, burn entry point, tax, blacklist,
pause, confiscation, proxy, or upgrade. Maximum-uint approvals follow ordinary
ERC-20 unlimited allowance semantics; users should approve only needed amounts.

The brief does not specify how races are conducted or how their outcomes reach
Ethereum. This implementation assumes **externally conducted hamster races and
a trusted result reporter**, configured by the launch owner after deployment.
It does not invent an oracle address or generate random race outcomes.
The reporter can select the reported winner or void a race; participants must
trust its honesty and the event operator. This is not a verifiable-randomness
lottery or a trustless sports oracle.

ETH is the betting asset. Rewards are existing HAMSTER voluntarily escrowed by
the owner for each race. Neither betting nor losing can mint more HAMSTER.
Payouts are pari-mutuel: winners share the ETH pot and losers share the reward
budget in proportion to their stakes. There is no fixed price, guaranteed
exchange rate, fixed odds, or application fee. Additional bets change the
eventual proportions until entry closes.

## Build and check

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xa2c2ce5c4cdf04a622dd5f7f629b355a1d3e5725c51d39de7a1da58a331de5c1 forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun EVM, optimizer runs 200, and
`bytecode_hash = "none"`. All source dependencies are vendored as ordinary files
in `lib/`; no network, submodules, package installation, environment configuration,
FFI, or filesystem permissions are needed by the project or its tests. Dependency
versions, archive digests, and licenses are recorded in `lib/DEPENDENCIES.md`.
With the pinned compiler installed, `forge build --offline` and
`forge test --offline` work as well.

Tests cover ERC-20 success/failure paths, mint destination and launch transfer
amounts, factory/application separation, funded races, payouts, rounding,
refunds, deadlines, unauthorized/duplicate actions, reporter changes, ownership
transfer, token payment failure, rejecting ETH recipients, and reentrancy.
Fuzz tests use 512 inputs per test. The stateful invariant test runs 128 sequences
of 64 actions across multiple races, checks both asset ledgers and fixed supply,
then exercises timeout/refund/claim paths to drain all legitimate liabilities.
Tests use isolated fixtures and do not read or modify environment variables.

The supplied protected harness is an independent verifier input, not a local
dependency. It imports network harness contracts absent from this assignment and
requires verifier-provided launch data. Local launch-flow tests check exact
token transfers and constructor behavior; they do not claim to execute the full
protected Uniswap v4 integration harness.

## Deployment

Deploy in this order on Ethereum (chain ID 1):

1. `HamsterToken()` through the launch factory. The **factory**, as constructor
   caller, receives the entire supply; no application receives a launch allocation.
2. `HamsterRaces(hamster_, owner_)`, where `hamster_` is that deployed token and
   `owner_` is the launch owner's address supplied by the launch process. Do not
   use the deploying factory as the owner. Both arguments must be nonzero.

These are immutable contracts. Their constructors make no external calls, require
no external contract code, and do not fund or initialize races. Both Solidity
identifiers fit the launch's 32-character limit. No libraries need linking.
`HamsterRaces` checks token code and exact token receipt on first funding.

The separate launch process prepares `launch.json` and carries out deployment,
liquidity provisioning, and distribution. There is intentionally no launch
manifest, transaction broadcast, private key, or preassigned reporter here.
The launch's distribution remains 10% to its distributor, 50% to the pool, and
40% to the specified remainder recipient, all from the factory's initial balance.
The race application does not access or implement those distribution operations.
The launch's IMD trading pair is separate from the application's ETH bets.

## After launch

The launch owner must call **`setResultReporter(address reporter)`** with the
actual address controlled by the chosen race-result attestation operator or
its multisig. Obtain that address from that operator through an authenticated
channel. It may be an EOA or a contract capable of calling the reporting methods.
Zero and the race contract itself are rejected. Until configured,
`createRace` reverts with `ReporterNotConfigured`.

Changing the reporter emits `ResultReporterSet` and affects only future races.
Each existing race retains its original reporter, even if that reporter loses
its key or the owner changes. Such a race can still time out and refund.

To operate a race:

1. Publish the external race's rules, hamster numbers, identity, event schedule,
   reporter identity, and cancellation conditions. Use a unique nonzero
   `raceReference`, for example the hash of its canonical published description.
   The contract stores the reference; it cannot verify the description or event.
2. Choose `hamsterCount`, `closesAt`, and a positive `rewardBudget`. Set the close
   before the actual race begins, and ensure the event can finish within the
   following day. Acquire existing HAMSTER and approve exactly `rewardBudget`
   minor units to the application from the owner's wallet.
3. The owner calls `createRace(raceReference, hamsterCount, closesAt, rewardBudget)`.
   All rewards are transferred into escrow atomically. Failed or short funding
   creates no race and consumes no race reference. Publish the resulting race ID
   and the actual on-chain terms, available through `getRace` and `RaceCreated`.
4. Participants call `placeBet(raceId, hamsterNumber)` with their ETH stake as
   `msg.value`. They should inspect the event, reporter, escrow, and deadlines
   before betting. One immutable bet per address per race is accepted; bets
   cannot be topped up, switched, or withdrawn while a race is active.
5. After entry closes and the external result is known, the snapshotted reporter
   calls `reportResult(raceId, winner)`. For an abandoned/invalid event it calls
   `cancelRace(raceId)`. Reporting never pushes payments to bettors.
6. Each bettor calls `claim(raceId, recipient)` from the betting address.
   Winners receive ETH, losers receive HAMSTER, and cancelled bets receive their
   full ETH stake. Contract wallets can choose a recipient that accepts ETH.
7. If a race is cancelled or has no losing bets, its original sponsor calls
   `reclaimRewards(raceId, recipient)` to recover unused HAMSTER. Anyone can
   trigger timeout cancellation; there is no keeper-only dependency.

There are no further deployment settings, subscriptions, prices, or fee rates.
Reward budgets and race schedules are per-event inputs, publicly fixed before
any bets are accepted. A reward budget is a voluntary funding amount, not a
promised HAMSTER-per-ETH rate.

## Rules, transitions, and accounting

| Item | Value or behavior |
| --- | --- |
| `MIN_HAMSTERS` / `MAX_HAMSTERS` | 2 / 16, numbered from 1 |
| `MAX_ENTRY_WINDOW` | 7 days; creation requires `now < closesAt <= now + 7 days` |
| `RESULT_WINDOW` | 1 day; `resolveBy = closesAt + 1 day` |
| Bet size | Any positive number of wei |
| Entry | Allowed strictly before `closesAt` |
| Reporting | Allowed at `closesAt <= now < resolveBy` |
| Reporter cancellation | Allowed any time while the race is not final |
| Public timeout cancellation | Allowed at `now >= resolveBy` |
| Claims | One per bettor, no expiry, no privileged sweep |

The participant and time bounds above are implementation choices. Timestamps
gate deadlines only; they never supply randomness or choose the winner.

`Open` covers both entry time and the waiting-for-result period; inspect the
timestamps to distinguish them. A valid result with winning bets moves the race
to `Settled`. Reporter cancellation, timeout, or a result with no winning bets
moves it to `Cancelled`. Both terminal states are irreversible. A race with no
bets can be finalized and its budget recovered. Results cannot be edited or
resubmitted, and a final race rejects further bets.

For a settled race with total ETH stake `T`, winning stake `W`, losing stake
`L = T - W`, HAMSTER budget `R`, and an individual stake `s`:

- Winning ETH share: `floor(T * s / W)`.
- Losing HAMSTER share: `floor(R * s / L)`.
- The last claimant **within each group** receives that group's remainder,
  including rounding dust. Arithmetic uses full-precision `Math.mulDiv`.
- A very small losing stake may round down to zero minor units. Splitting bets
  or claiming later does not create rewards beyond the funded budget.

If `W == 0`, the race is cancelled, every stake is refunded, and the sponsor
can recover all rewards. If `L == 0`, winners recover their own stakes and the
sponsor can recover all rewards. Cancelled races never pay loss rewards.
Refunds are exactly the original stake, independent of claim order.

For example, bets of 1 ETH and 3 ETH on the winner share a 10 ETH pot as 2.5 ETH
and 7.5 ETH. Losing bets of 2 ETH and 4 ETH share a 1,000 HAMSTER reward budget
in a 1:2 ratio, with any minor-unit dust assigned to the last losing claimant.

`ethLiability` and `rewardLiability` track unwithdrawn obligations across all
races. Round balances and remaining stake weights are updated before any
payment. Reentrancy protection covers all escrow-changing entry points.
An unsuccessful ETH or token payment reverts all claim state; it can be retried
without affecting other participants. Settlement and cancellation do not loop
over bettors. Unclaimed awards remain reserved indefinitely.

## Responsibilities and limitations

The owner funds and schedules new races and selects reporters for future races.
The current owner can nominate a successor with `transferOwnership`, and that
address must call `acceptOwnership`. The original funder of a race remains its
sponsor after ownership changes. Inherited `renounceOwnership` permanently
disables creation and configuration; it does not disable existing reporters,
timeouts, claims, or sponsor refunds.

The reporter controls outcome integrity and may cancel even after seeing an
event's result. There is no on-chain dispute process. The owner/operator must
publish this trust model, close entry before outcome information is available,
report accurately and promptly, monitor outstanding races, and arrange
operational coverage. A lost or silent reporter causes refunds at timeout;
a dishonest reporter can misallocate the ETH pot and HAMSTER reward budget.

One address is not one person: users can bet on multiple hamsters using multiple
addresses, including deliberate losing bets to compete for rewards. The sponsor
must account for that incentive when funding races. Loss rewards do not promise
profit, compensation equal to an ETH loss, or any market value.

Only send ETH through `placeBet` and fund HAMSTER through `createRace`.
Unsolicited ERC-20 transfers and forcibly sent ETH are not credited to bets or
rewards and have no recovery method. This avoids giving an administrator a
general withdrawal power. Users must also select the correct claim recipient;
successful transfers to an unintended address cannot be undone.

See `SECURITY.md` for the local review and verification scope. Independent
adversarial review remains a release responsibility before accepting public
funds; passing local tests is not an independent security audit.
