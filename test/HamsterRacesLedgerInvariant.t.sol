// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterRaces} from "../src/HamsterRaces.sol";

/// @dev Drives HamsterRaces with separate owner, reporter, sponsor and bettor roles, rotates the reporter,
///      routes claims to third-party recipients and probes unauthorized calls. Every call is guarded so a
///      handler step never reverts; an unauthorized call that succeeds is recorded as a violation.
contract LedgerHandler is Test {
    HamsterToken public immutable token;
    HamsterRaces public immutable races;
    address public immutable owner = address(0xA11CE);
    address public immutable outsider = address(0xBAD);
    address[] public reporters;
    address[5] public bettors;
    address[3] public recipients;

    struct Terms {
        address reporter;
        address sponsor;
        uint64 closesAt;
        uint64 resolveBy;
        uint8 hamsterCount;
        uint256 rewardBudget;
    }

    mapping(uint256 => Terms) public terms;
    // Highest status ever observed per race: Open(1) -> Settled(2) | Cancelled(3); never back.
    mapping(uint256 => HamsterRaces.Status) public seenStatus;
    mapping(uint256 => uint8) public seenWinner;
    mapping(uint256 => mapping(address => uint256)) public stakeOf;
    mapping(uint256 => mapping(address => uint8)) public pickOf;
    mapping(uint256 => mapping(address => uint256)) public ethPaidTo;
    mapping(uint256 => mapping(address => uint256)) public rewardPaidTo;
    mapping(uint256 => uint256) public ethPaidByRace;
    mapping(uint256 => uint256) public rewardsPaidByRace;
    mapping(uint256 => uint256) public reclaimedByRace;

    uint256 public depositedEth;
    uint256 public paidEth;
    uint256 public fundedRewards;
    uint256 public paidRewards;
    uint256 public reclaimedRewards;
    uint256 public violations;
    string public lastViolation;

    constructor(HamsterToken token_) {
        token = token_;
        races = new HamsterRaces(token_, owner);
        reporters.push(address(0x5EE1));
        vm.prank(owner);
        races.setResultReporter(reporters[0]);
        for (uint256 i; i < bettors.length; ++i) {
            bettors[i] = address(uint160(0xB000 + i));
        }
        for (uint256 i; i < recipients.length; ++i) {
            recipients[i] = address(uint160(0xC000 + i));
        }
    }

    // ---------------------------------------------------------------- actions

    function rotateReporter(uint8 seed) external {
        address next = address(uint160(0x5EE1 + 1 + (seed % 3)));
        reporters.push(next);
        vm.prank(owner);
        races.setResultReporter(next);
    }

    function openRace(uint8 count, uint32 duration, uint96 reward) external {
        if (races.raceCount() >= 6) return;
        uint256 budget = bound(uint256(reward), 1, 50_000 ether);
        if (token.balanceOf(owner) < budget) return;
        uint8 hamsters = uint8(bound(count, 2, 16));
        uint64 closesAt = uint64(block.timestamp + bound(duration, 1, 2 days));
        vm.startPrank(owner);
        token.approve(address(races), budget);
        uint256 id =
            races.createRace(keccak256(abi.encode("ledger", races.raceCount() + 1)), hamsters, closesAt, budget);
        vm.stopPrank();
        terms[id] = Terms(races.resultReporter(), owner, closesAt, closesAt + 1 days, hamsters, budget);
        fundedRewards += budget;
        _observe(id);
    }

    function bet(uint256 seed, uint8 who, uint8 pick, uint96 stake) external {
        uint256 id = _id(seed);
        if (id == 0) return;
        HamsterRaces.Race memory race = races.getRace(id);
        if (race.status != HamsterRaces.Status.Open || block.timestamp >= race.closesAt) return;
        address bettor = bettors[who % bettors.length];
        if (stakeOf[id][bettor] != 0) return;
        uint256 amount = bound(uint256(stake), 1, 50 ether);
        uint8 hamster = uint8(bound(pick, 1, race.hamsterCount));
        vm.deal(bettor, bettor.balance + amount);
        vm.prank(bettor);
        races.placeBet{value: amount}(id, hamster);
        stakeOf[id][bettor] = amount;
        pickOf[id][bettor] = hamster;
        depositedEth += amount;
    }

    function warp(uint32 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1, 18 hours));
    }

    function report(uint256 seed, uint8 winnerSeed) external {
        uint256 id = _id(seed);
        if (id == 0) return;
        HamsterRaces.Race memory race = races.getRace(id);
        if (
            race.status != HamsterRaces.Status.Open || block.timestamp < race.closesAt
                || block.timestamp >= race.resolveBy
        ) return;
        uint8 winner = uint8(bound(winnerSeed, 1, race.hamsterCount));
        vm.prank(race.reporter);
        races.reportResult(id, winner);
        seenWinner[id] = winner;
        _observe(id);
    }

    function cancel(uint256 seed, bool asReporter) external {
        uint256 id = _id(seed);
        if (id == 0) return;
        HamsterRaces.Race memory race = races.getRace(id);
        if (race.status != HamsterRaces.Status.Open) return;
        if (!asReporter && block.timestamp < race.resolveBy) return;
        vm.prank(asReporter ? race.reporter : outsider);
        races.cancelRace(id);
        _observe(id);
    }

    function claim(uint256 seed, uint8 who, uint8 to) external {
        uint256 id = _id(seed);
        if (id != 0) _claim(id, bettors[who % bettors.length], recipients[to % recipients.length]);
    }

    function reclaim(uint256 seed) external {
        uint256 id = _id(seed);
        if (id != 0) _reclaim(id);
    }

    /// @dev Calls that must fail for the caller/state chosen; success is a violation.
    function probe(uint256 seed, uint8 kind, uint8 winnerSeed) external {
        uint256 id = _id(seed);
        if (id == 0) return;
        HamsterRaces.Race memory race = races.getRace(id);
        uint8 winner = uint8(bound(winnerSeed, 1, race.hamsterCount));
        kind = kind % 6;
        if (kind == 0) {
            // A stale reporter or outsider reports a result.
            address caller = race.reporter == reporters[0] && reporters.length > 1 ? reporters[1] : outsider;
            if (caller == race.reporter) caller = outsider;
            vm.prank(caller);
            try races.reportResult(id, winner) {
                _violate("non-reporter reported a result");
            } catch {}
        } else if (kind == 1) {
            // Outsider cancels before the result deadline.
            if (block.timestamp >= race.resolveBy) return;
            vm.prank(outsider);
            try races.cancelRace(id) {
                _violate("outsider cancelled before timeout");
            } catch {}
        } else if (kind == 2) {
            // Non-sponsor reclaims rewards.
            vm.prank(bettors[winner % bettors.length]);
            try races.reclaimRewards(id, outsider) {
                _violate("non-sponsor reclaimed rewards");
            } catch {}
        } else if (kind == 3) {
            // Sponsor reclaims while losers are owed rewards or the race is open.
            if (race.status == HamsterRaces.Status.Cancelled) return;
            if (race.status == HamsterRaces.Status.Settled && race.totalStaked == races.stakes(id, race.winner)) {
                return;
            }
            vm.prank(owner);
            try races.reclaimRewards(id, owner) {
                _violate("sponsor reclaimed owed or active rewards");
            } catch {}
        } else if (kind == 4) {
            // Outsider with no bet claims.
            vm.prank(outsider);
            try races.claim(id, payable(outsider)) {
                _violate("claim without a bet succeeded");
            } catch {}
        } else {
            // A bettor who already claimed claims again, or a bet lands after close.
            address bettor = bettors[winner % bettors.length];
            (uint256 amount,, bool claimed) = races.bets(id, bettor);
            if (amount != 0 && claimed) {
                vm.prank(bettor);
                try races.claim(id, payable(bettor)) {
                    _violate("double claim succeeded");
                } catch {}
            } else if (block.timestamp >= race.closesAt) {
                vm.deal(outsider, 1 ether);
                vm.prank(outsider);
                try races.placeBet{value: 1 ether}(id, 1) {
                    _violate("bet after close succeeded");
                } catch {}
            }
        }
    }

    /// @dev Finish every race and pay every entitlement, so the suite proves funds stay withdrawable.
    function drainAll() external {
        uint256 count = races.raceCount();
        uint256 latest = block.timestamp;
        for (uint256 id = 1; id <= count; ++id) {
            if (terms[id].resolveBy > latest) latest = terms[id].resolveBy;
        }
        vm.warp(latest);
        for (uint256 id = 1; id <= count; ++id) {
            if (races.getRace(id).status == HamsterRaces.Status.Open) {
                vm.prank(outsider);
                races.cancelRace(id);
                _observe(id);
            }
            for (uint256 i; i < bettors.length; ++i) {
                _claim(id, bettors[i], bettors[i]);
            }
            _reclaim(id);
        }
    }

    // ---------------------------------------------------------------- views for invariants

    function reporterCount() external view returns (uint256) {
        return reporters.length;
    }

    function bettorCount() external view returns (uint256) {
        return bettors.length;
    }

    // ---------------------------------------------------------------- internals

    function _claim(uint256 id, address bettor, address recipient) private {
        if (races.getRace(id).status == HamsterRaces.Status.Open) return;
        (uint256 amount,, bool claimed) = races.bets(id, bettor);
        if (amount == 0 || claimed) return;
        uint256 ethBefore = recipient.balance;
        uint256 tokBefore = token.balanceOf(recipient);
        vm.prank(bettor);
        (uint256 ethAmount, uint256 rewardAmount) = races.claim(id, payable(recipient));
        if (recipient.balance - ethBefore != ethAmount) _violate("ETH delivered differs from return value");
        if (token.balanceOf(recipient) - tokBefore != rewardAmount) _violate("HAMSTER delivered differs from return");
        ethPaidTo[id][bettor] += ethAmount;
        rewardPaidTo[id][bettor] += rewardAmount;
        ethPaidByRace[id] += ethAmount;
        rewardsPaidByRace[id] += rewardAmount;
        paidEth += ethAmount;
        paidRewards += rewardAmount;
    }

    function _reclaim(uint256 id) private {
        HamsterRaces.Race memory race = races.getRace(id);
        if (race.status == HamsterRaces.Status.Open || race.rewardsRemaining == 0) return;
        if (race.status == HamsterRaces.Status.Settled && race.totalStaked != races.stakes(id, race.winner)) return;
        vm.prank(owner);
        uint256 amount = races.reclaimRewards(id, owner);
        reclaimedByRace[id] += amount;
        reclaimedRewards += amount;
    }

    function _observe(uint256 id) private {
        HamsterRaces.Status current = races.getRace(id).status;
        HamsterRaces.Status seen = seenStatus[id];
        if (seen == HamsterRaces.Status.Settled || seen == HamsterRaces.Status.Cancelled) {
            if (current != seen) _violate("final race changed status");
        }
        seenStatus[id] = current;
    }

    function _violate(string memory reason) private {
        ++violations;
        lastViolation = reason;
    }

    function _id(uint256 seed) private view returns (uint256) {
        uint256 count = races.raceCount();
        return count == 0 ? 0 : 1 + seed % count;
    }
}

contract HamsterRacesLedgerInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    HamsterToken internal token;
    HamsterRaces internal races;
    LedgerHandler internal handler;

    function setUp() public {
        vm.warp(2_000_000);
        token = new HamsterToken();
        handler = new LedgerHandler(token);
        races = handler.races();
        token.transfer(handler.owner(), 200_000 ether);
        handler.openRace(4, 3 hours, 5_000 ether);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = LedgerHandler.openRace.selector;
        selectors[1] = LedgerHandler.bet.selector;
        selectors[2] = LedgerHandler.warp.selector;
        selectors[3] = LedgerHandler.report.selector;
        selectors[4] = LedgerHandler.cancel.selector;
        selectors[5] = LedgerHandler.claim.selector;
        selectors[6] = LedgerHandler.reclaim.selector;
        selectors[7] = LedgerHandler.probe.selector;
        selectors[8] = LedgerHandler.rotateReporter.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_NoUnauthorizedOrRepeatedActionSucceeds() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_ContractHoldsExactlyWhatItOwes() public view {
        uint256 ethOwed;
        uint256 rewardsOwed;
        for (uint256 id = 1; id <= races.raceCount(); ++id) {
            HamsterRaces.Race memory race = races.getRace(id);
            ethOwed += race.ethRemaining;
            rewardsOwed += race.rewardsRemaining;
        }
        assertEq(address(races).balance, ethOwed, "ETH held != per-race ETH owed");
        assertEq(races.ethLiability(), ethOwed, "ethLiability != per-race ETH owed");
        assertEq(token.balanceOf(address(races)), rewardsOwed, "HAMSTER held != per-race rewards owed");
        assertEq(races.rewardLiability(), rewardsOwed, "rewardLiability != per-race rewards owed");
        assertEq(address(races).balance, handler.depositedEth() - handler.paidEth());
        assertEq(rewardsOwed, handler.fundedRewards() - handler.paidRewards() - handler.reclaimedRewards());
        assertEq(token.totalSupply(), SUPPLY, "fixed supply changed");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_EachRaceConservesStakesAndBudget() public view {
        for (uint256 id = 1; id <= races.raceCount(); ++id) {
            HamsterRaces.Race memory race = races.getRace(id);
            uint256 byHamster;
            for (uint8 h = 1; h <= 16; ++h) {
                byHamster += races.stakes(id, h);
            }
            assertEq(byHamster, race.totalStaked, "stakes by hamster != totalStaked");
            assertEq(race.ethRemaining + handler.ethPaidByRace(id), race.totalStaked, "race ETH leaked");
            assertEq(
                race.rewardsRemaining + handler.rewardsPaidByRace(id) + handler.reclaimedByRace(id),
                race.rewardBudget,
                "race budget leaked"
            );
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_TermsAreImmutableAndFinalStatesNeverReopen() public view {
        for (uint256 id = 1; id <= races.raceCount(); ++id) {
            HamsterRaces.Race memory race = races.getRace(id);
            (address reporter, address sponsor, uint64 closesAt, uint64 resolveBy, uint8 count, uint256 budget) =
                handler.terms(id);
            assertEq(race.reporter, reporter);
            assertEq(race.sponsor, sponsor);
            assertEq(race.closesAt, closesAt);
            assertEq(race.resolveBy, resolveBy);
            assertEq(race.hamsterCount, count);
            assertEq(race.rewardBudget, budget);
            assertEq(uint8(race.status), uint8(handler.seenStatus(id)), "status changed outside observed paths");
            if (race.status == HamsterRaces.Status.Settled) {
                assertEq(race.winner, handler.seenWinner(id));
                assertGt(races.stakes(id, race.winner), 0, "settled race without a winning stake");
            }
            if (race.status == HamsterRaces.Status.Open) {
                assertEq(race.winner, 0);
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_EveryPayoutMatchesItsBetsOutcome() public view {
        uint256 n = handler.bettorCount();
        for (uint256 id = 1; id <= races.raceCount(); ++id) {
            HamsterRaces.Race memory race = races.getRace(id);
            uint256 winningStake = race.status == HamsterRaces.Status.Settled ? races.stakes(id, race.winner) : 0;
            for (uint256 i; i < n; ++i) {
                address bettor = handler.bettors(i);
                uint256 stake = handler.stakeOf(id, bettor);
                uint256 ethPaid = handler.ethPaidTo(id, bettor);
                uint256 rewardPaid = handler.rewardPaidTo(id, bettor);
                (uint256 recorded, uint8 pick, bool claimed) = races.bets(id, bettor);
                assertEq(recorded, stake, "bet amount changed");
                assertEq(pick, handler.pickOf(id, bettor), "bet pick changed");
                if (!claimed) {
                    assertEq(ethPaid + rewardPaid, 0, "unclaimed bet was paid");
                    continue;
                }
                assertTrue(ethPaid == 0 || rewardPaid == 0, "one bet paid in both assets");
                if (race.status == HamsterRaces.Status.Cancelled) {
                    assertEq(ethPaid, stake, "cancelled race refund != stake");
                    assertEq(rewardPaid, 0);
                } else if (pick == race.winner) {
                    // Proportional share, rounded down, plus at most the dust left by other winners.
                    uint256 fair = race.totalStaked * stake / winningStake;
                    assertGe(ethPaid, fair, "winner paid below proportional share");
                    assertLe(ethPaid, fair + n, "winner paid more than share plus dust");
                    assertEq(rewardPaid, 0);
                } else {
                    uint256 fairReward = race.rewardBudget * stake / (race.totalStaked - winningStake);
                    assertEq(ethPaid, 0, "loser received ETH");
                    assertGe(rewardPaid, fairReward, "loser reward below proportional share");
                    assertLe(rewardPaid, fairReward + n, "loser reward above share plus dust");
                }
            }
        }
    }

    function afterInvariant() public {
        handler.drainAll();
        assertEq(handler.violations(), 0, handler.lastViolation());
        assertEq(address(races).balance, 0, "ETH stranded after every claim");
        assertEq(token.balanceOf(address(races)), 0, "HAMSTER stranded after every claim and reclaim");
        assertEq(races.ethLiability(), 0);
        assertEq(races.rewardLiability(), 0);
        assertEq(handler.depositedEth(), handler.paidEth());
        assertEq(handler.fundedRewards(), handler.paidRewards() + handler.reclaimedRewards());
    }
}
