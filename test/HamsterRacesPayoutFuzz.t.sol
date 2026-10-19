// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RaceTestBase} from "./helpers/RaceTestBase.sol";
import {HamsterRaces} from "../src/HamsterRaces.sol";

/// @dev Stateless property tests of the payout arithmetic with up to 8 bettors and any claim order.
contract HamsterRacesPayoutFuzzTest is RaceTestBase {
    uint256 internal constant MAX_BETTORS = 8;

    function _bettor(uint256 i) internal pure returns (address) {
        return address(uint160(0xF000 + i));
    }

    /// @dev Places one bet per bettor, hamster 1 or 2 chosen by `picks` bits, and returns the stakes.
    function _placeMany(uint256 n, uint256 seed, uint256 picks, uint256 maxStake)
        internal
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            amounts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, maxStake);
            address bettor = _bettor(i);
            vm.deal(bettor, amounts[i]);
            vm.prank(bettor);
            races.placeBet{value: amounts[i]}(raceId, uint8(1 + ((picks >> i) & 1)));
        }
    }

    /// @dev Claims in a permutation of 0..n-1 derived from `orderSeed` (Fisher-Yates).
    function _order(uint256 n, uint256 orderSeed) internal pure returns (uint256[] memory order) {
        order = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            order[i] = i;
        }
        for (uint256 i = n; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(orderSeed, i))) % i;
            (order[i - 1], order[j]) = (order[j], order[i - 1]);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EveryClaimOrderPaysProportionalSharesAndEmptiesTheRace(
        uint8 nSeed,
        uint256 stakeSeed,
        uint256 picks,
        uint256 orderSeed,
        uint256 maxStakeSeed
    ) public {
        uint256 n = bound(nSeed, 2, MAX_BETTORS);
        // Edge-heavy stake ceilings: 1 wei stakes up to stakes far beyond any real ETH supply.
        uint256 maxStake = [uint256(1), 3, 1 ether, 1e30][maxStakeSeed % 4];
        uint256[] memory amounts = _placeMany(n, stakeSeed, picks, maxStake);
        uint8 winner = uint8(1 + (orderSeed & 1));
        _settle(winner);

        HamsterRaces.Race memory race = races.getRace(raceId);
        if (race.status == HamsterRaces.Status.Cancelled) {
            // Nobody picked the winner: every bettor is refunded exactly.
            for (uint256 i; i < n; ++i) {
                vm.prank(_bettor(i));
                (uint256 refund, uint256 reward) = races.claim(raceId, payable(_bettor(i)));
                assertEq(refund, amounts[i]);
                assertEq(reward, 0);
            }
        } else {
            _claimSettled(amounts, picks, winner, orderSeed);
        }
        _reclaimRest();
        HamsterRaces.Race memory done = races.getRace(raceId);
        assertEq(done.ethRemaining, 0);
        assertEq(done.rewardsRemaining, 0);
        assertEq(done.lossRewardRemaining, 0);
        assertEq(done.winnerStakeRemaining, 0);
        assertEq(done.loserStakeRemaining, 0);
        assertEq(address(races).balance, 0);
        assertEq(races.ethLiability(), 0);
        // Only the setUp race's escrow, now fully paid or reclaimed, is gone; nothing is stranded.
        assertEq(races.rewardLiability(), 0);
        assertEq(token.balanceOf(address(races)), 0);
        _assertSolvent();
    }

    /// @dev The sponsor's share R - P is locked until resolveBy whenever losers share a nonzero pool, then
    ///      reclaimable exactly once; a race with nothing unowed left refuses.
    function _reclaimRest() internal {
        HamsterRaces.Race memory race = races.getRace(raceId);
        uint256 rest = race.rewardsRemaining - race.lossRewardRemaining;
        if (race.status == HamsterRaces.Status.Settled && race.lossRewardPool != 0) {
            vm.warp(race.resolveBy - 1);
            vm.prank(owner);
            vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
            races.reclaimRewards(raceId, owner);
            vm.warp(race.resolveBy);
        }
        vm.prank(owner);
        if (rest == 0) {
            vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
            races.reclaimRewards(raceId, owner);
            return;
        }
        assertEq(races.reclaimRewards(raceId, owner), rest);
        assertEq(rest, REWARD - race.lossRewardPool, "sponsor share != R - P");
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
        races.reclaimRewards(raceId, owner);
    }

    uint256 internal totalStaked_;
    uint256 internal lossPool_;
    uint256 internal winningStake_;
    uint256 internal losingStake_;

    function _claimSettled(uint256[] memory amounts, uint256 picks, uint8 winner, uint256 orderSeed) internal {
        totalStaked_ = races.getRace(raceId).totalStaked;
        winningStake_ = races.stakes(raceId, winner);
        losingStake_ = totalStaked_ - winningStake_;
        lossPool_ = REWARD * losingStake_ / totalStaked_;
        assertEq(races.getRace(raceId).lossRewardPool, lossPool_, "loss pool != floor(R * L / T)");
        uint256[] memory order = _order(amounts.length, orderSeed);
        uint256 ethOut;
        uint256 rewardOut;
        for (uint256 k; k < amounts.length; ++k) {
            uint256 i = order[k];
            (uint256 ethAmount, uint256 reward) =
                _claimAndCheck(i, amounts[i], (picks >> i) & 1 == winner - 1, amounts.length);
            ethOut += ethAmount;
            rewardOut += reward;
        }
        assertEq(ethOut, totalStaked_, "winners did not split the whole pot");
        assertEq(rewardOut, lossPool_, "losers did not split exactly the loss pool");
    }

    function _claimAndCheck(uint256 i, uint256 amount, bool won, uint256 n)
        internal
        returns (uint256 ethAmount, uint256 reward)
    {
        vm.prank(_bettor(i));
        (ethAmount, reward) = races.claim(raceId, payable(_bettor(i)));
        if (won) {
            uint256 fair = totalStaked_ * amount / winningStake_;
            assertGe(ethAmount, fair, "winner short-changed");
            assertLe(ethAmount, fair + n, "winner overpaid beyond dust");
            assertGe(ethAmount, amount, "winner received less than own stake");
            assertEq(reward, 0);
        } else {
            uint256 fairReward = lossPool_ * amount / losingStake_;
            assertEq(ethAmount, 0);
            assertGe(reward, fairReward, "loser short-changed");
            assertLe(reward, fairReward + n, "loser overpaid beyond dust");
            assertLe(reward, REWARD * amount / totalStaked_ + n, "loser paid above R / T per losing wei");
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RewardBudgetEdgesSplitExactly(uint256 budgetSeed, uint256 stakeSeed, uint256 orderSeed) public {
        uint256 budget = [uint256(1), 2, 7, 500_000 ether][budgetSeed % 4];
        closesAt = uint64(block.timestamp + 1 hours);
        raceId = _create(keccak256(abi.encode("edge budget", budgetSeed)), 2, budget);
        uint256 losers = 5;
        uint256[] memory amounts = new uint256[](losers + 1);
        for (uint256 i; i <= losers; ++i) {
            amounts[i] = bound(uint256(keccak256(abi.encode(stakeSeed, i))), 1, 10 ether);
            vm.deal(_bettor(i), amounts[i]);
            vm.prank(_bettor(i));
            // Bettor 0 wins on hamster 1; the rest lose on hamster 2.
            races.placeBet{value: amounts[i]}(raceId, i == 0 ? 1 : 2);
        }
        _settle(1);
        uint256 staked;
        for (uint256 i; i <= losers; ++i) {
            staked += amounts[i];
        }
        uint256 pool = budget * (staked - amounts[0]) / staked;
        HamsterRaces.Race memory race = races.getRace(raceId);
        assertEq(race.lossRewardPool, pool);
        uint256[] memory order = _order(losers + 1, orderSeed);
        uint256 total;
        for (uint256 k; k <= losers; ++k) {
            vm.prank(_bettor(order[k]));
            (, uint256 reward) = races.claim(raceId, payable(_bettor(order[k])));
            total += reward;
        }
        assertEq(total, pool);
        assertEq(races.getRace(raceId).lossRewardRemaining, 0);
        // A nonzero pool locks the sponsor's share until resolveBy; a pool rounded to zero does not.
        vm.prank(owner);
        if (pool != 0) {
            vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
            races.reclaimRewards(raceId, owner);
            vm.warp(race.resolveBy);
            vm.prank(owner);
        }
        assertEq(races.reclaimRewards(raceId, owner), budget - pool);
        // Only the untouched setUp race's escrow remains.
        assertEq(token.balanceOf(address(races)), REWARD);
        assertEq(races.rewardLiability(), REWARD);
        assertEq(races.getRace(raceId).rewardsRemaining, 0);
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
        races.reclaimRewards(raceId, owner);
    }

    /// @dev budget - pool is never zero (the winner always holds stake), so reclaim always has something.
    function test_TinyBudgetRoundsLossPoolToZeroAndIsReclaimableAtOnce() public {
        closesAt = uint64(block.timestamp + 1 hours);
        raceId = _create(keccak256("one unit"), 2, 1);
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 1 ether);
        _settle(1);
        assertEq(races.getRace(raceId).lossRewardPool, 0);
        (, uint256 reward) = _claim(bob);
        assertEq(reward, 0);
        vm.prank(owner);
        assertEq(races.reclaimRewards(raceId, owner), 1);
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ResultWindowBoundaries(uint256 offset) public {
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 1 ether);
        uint256 resolveBy = races.getRace(raceId).resolveBy;
        uint256 t = bound(offset, closesAt - 1 hours, resolveBy + 2 days);
        vm.warp(t);
        vm.prank(reporter);
        if (t < closesAt) {
            vm.expectRevert(HamsterRaces.BettingStillOpen.selector);
            races.reportResult(raceId, 1);
        } else if (t >= resolveBy) {
            vm.expectRevert(HamsterRaces.ResultDeadlinePassed.selector);
            races.reportResult(raceId, 1);
            // ...and from then on anyone can void it.
            vm.prank(carol);
            races.cancelRace(raceId);
            assertEq(uint8(races.getRace(raceId).status), uint8(HamsterRaces.Status.Cancelled));
        } else {
            races.reportResult(raceId, 1);
            assertEq(uint8(races.getRace(raceId).status), uint8(HamsterRaces.Status.Settled));
        }
        // Betting is open strictly before closesAt and never after it.
        vm.deal(dave, 1 ether);
        vm.prank(dave);
        if (t < closesAt) {
            races.placeBet{value: 1 ether}(raceId, 1);
        } else {
            vm.expectRevert();
            races.placeBet{value: 1 ether}(raceId, 1);
        }
    }

    function test_ReporterCannotCancelAfterSettlingAndOutsiderCannotCancelAtResolveByMinusOne() public {
        _bet(alice, 1, 1 ether);
        uint64 resolveBy = races.getRace(raceId).resolveBy;
        vm.warp(resolveBy - 1);
        vm.prank(carol);
        vm.expectRevert(HamsterRaces.CancellationNotAllowed.selector);
        races.cancelRace(raceId);
        vm.prank(reporter);
        races.reportResult(raceId, 1);
        vm.prank(reporter);
        vm.expectRevert(HamsterRaces.RaceNotOpen.selector);
        races.cancelRace(raceId);
        vm.warp(resolveBy + 1);
        vm.prank(carol);
        vm.expectRevert(HamsterRaces.RaceNotOpen.selector);
        races.cancelRace(raceId);
    }

    function test_ReportingAWinnerNobodyBackedVoidsTheRaceAndReturnsBudget() public {
        _bet(alice, 1, 2 ether);
        _bet(bob, 2, 3 ether);
        _settle(3);
        HamsterRaces.Race memory race = races.getRace(raceId);
        assertEq(uint8(race.status), uint8(HamsterRaces.Status.Cancelled));
        assertEq(race.winner, 3);
        (uint256 refundA, uint256 rewardA) = _claim(alice);
        (uint256 refundB, uint256 rewardB) = _claim(bob);
        assertEq(refundA, 2 ether);
        assertEq(refundB, 3 ether);
        assertEq(rewardA + rewardB, 0);
        vm.prank(owner);
        assertEq(races.reclaimRewards(raceId, owner), REWARD);
        _assertSolvent();
    }
}
