// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RaceTestBase} from "./helpers/RaceTestBase.sol";
import {HamsterRaces} from "../src/HamsterRaces.sol";

contract HamsterRacesTest is RaceTestBase {
    function test_CreationEscrowsRewardsAndPublishesTerms() public view {
        HamsterRaces.Race memory race = races.getRace(raceId);
        assertEq(race.raceReference, keccak256("race one"));
        assertEq(race.reporter, reporter);
        assertEq(race.sponsor, owner);
        assertEq(race.hamsterCount, 3);
        assertEq(race.closesAt, closesAt);
        assertEq(race.resolveBy, closesAt + 1 days);
        assertEq(uint8(race.status), uint8(HamsterRaces.Status.Open));
        assertEq(race.rewardBudget, REWARD);
        assertEq(race.rewardsRemaining, REWARD);
        assertEq(races.raceIds(race.raceReference), raceId);
        assertEq(token.balanceOf(address(races)), REWARD);
        assertEq(token.allowance(owner, address(races)), 0);
        _assertSolvent();
    }

    function test_WinnersReceiveEthAndLosersEarnHamster() public {
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 2 ether);
        _bet(carol, 1, 3 ether);
        _bet(dave, 3, 4 ether);
        _settle(1);

        (uint256 ethAmount, uint256 reward) = _claim(alice);
        assertEq(ethAmount, 2.5 ether);
        assertEq(reward, 0);
        (ethAmount, reward) = _claim(bob);
        assertEq(ethAmount, 0);
        // Losers share R * L / T = 1000 * 6 / 10; bob holds 2 of the 6 losing ETH.
        assertEq(reward, 200 ether);
        _claim(carol);
        _claim(dave);
        vm.warp(closesAt + races.RESULT_WINDOW());
        vm.prank(owner);
        assertEq(races.reclaimRewards(raceId, owner), 400 ether);

        assertEq(alice.balance, 101.5 ether);
        assertEq(carol.balance, 104.5 ether);
        assertEq(bob.balance, 98 ether);
        assertEq(dave.balance, 96 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(bob), 200 ether);
        assertEq(token.balanceOf(dave), 400 ether);
        assertEq(token.balanceOf(owner), 1_000_000 ether - REWARD + 400 ether);
        assertEq(address(races).balance, 0);
        assertEq(token.balanceOf(address(races)), 0);
        assertEq(races.ethLiability(), 0);
        assertEq(races.rewardLiability(), 0);
        _assertSolvent();
    }

    function testFuzz_SettlementConservesBothAssets(uint96 a, uint96 b, uint96 c, uint96 d, bool reverse) public {
        uint256 aStake = bound(uint256(a), 1, 100 ether);
        uint256 bStake = bound(uint256(b), 1, 100 ether);
        uint256 cStake = bound(uint256(c), 1, 100 ether);
        uint256 dStake = bound(uint256(d), 1, 100 ether);
        _bet(alice, 1, aStake);
        _bet(bob, 2, bStake);
        _bet(carol, 1, cStake);
        _bet(dave, 3, dStake);
        _settle(1);

        if (reverse) {
            _claim(dave);
            _claim(carol);
            _claim(bob);
            _claim(alice);
        } else {
            _claim(alice);
            _claim(bob);
            _claim(carol);
            _claim(dave);
        }
        uint256 total = aStake + bStake + cStake + dStake;
        uint256 alicePayout = alice.balance - (100 ether - aStake);
        uint256 carolPayout = carol.balance - (100 ether - cStake);
        assertEq(alicePayout + carolPayout, total);
        assertGe(alicePayout, total * aStake / (aStake + cStake));
        assertGe(carolPayout, total * cStake / (aStake + cStake));
        uint256 lossPool = REWARD * (bStake + dStake) / total;
        assertEq(token.balanceOf(bob) + token.balanceOf(dave), lossPool);
        assertGe(token.balanceOf(bob), lossPool * bStake / (bStake + dStake));
        assertGe(token.balanceOf(dave), lossPool * dStake / (bStake + dStake));
        vm.warp(closesAt + races.RESULT_WINDOW());
        if (lossPool != REWARD) {
            vm.prank(owner);
            assertEq(races.reclaimRewards(raceId, owner), REWARD - lossPool);
        }
        assertEq(address(races).balance, 0);
        assertEq(token.balanceOf(address(races)), 0);
        assertEq(races.ethLiability(), 0);
        assertEq(races.rewardLiability(), 0);
        _assertSolvent();
    }

    function test_SmallestRewardUnitsAndDustAreAccountedFor() public {
        raceId = _create(keccak256("five minor unit reward"), 2, 5);
        _bet(alice, 1, 1);
        _bet(bob, 2, 1);
        _bet(carol, 2, 1);
        _settle(1);
        // Loss pool floor(5 * 2 / 3) = 3: bob floor(3 / 2) = 1, carol the dust-inclusive remainder 2.
        (, uint256 firstReward) = _claim(bob);
        (, uint256 lastReward) = _claim(carol);
        assertEq(firstReward, 1);
        assertEq(lastReward, 2);
        (uint256 ethAmount,) = _claim(alice);
        assertEq(ethAmount, 3);
        vm.warp(closesAt + races.RESULT_WINDOW());
        vm.prank(owner);
        assertEq(races.reclaimRewards(raceId, owner), 2);
        assertEq(races.rewardLiability(), REWARD);
        _assertSolvent();
    }

    function test_ReporterCanVoidAndAllStakesAreRefunded() public {
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 2 ether);
        vm.prank(reporter);
        races.cancelRace(raceId);
        _claim(bob);
        _claim(alice);
        assertEq(alice.balance, 100 ether);
        assertEq(bob.balance, 100 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        vm.prank(owner);
        assertEq(races.reclaimRewards(raceId, owner), REWARD);
        assertEq(token.balanceOf(owner), 1_000_000 ether);
        assertEq(races.ethLiability(), 0);
        assertEq(races.rewardLiability(), 0);
    }

    function test_AnyoneCanCancelAtExactTimeout() public {
        _bet(alice, 1, 7 ether);
        vm.warp(closesAt + races.RESULT_WINDOW());
        vm.prank(bob);
        races.cancelRace(raceId);
        _claim(alice);
        assertEq(alice.balance, 100 ether);
        assertEq(uint8(races.getRace(raceId).status), uint8(HamsterRaces.Status.Cancelled));
        _assertSolvent();
    }

    function test_NoWinningBetsMeansFullRefunds() public {
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 2 ether);
        _settle(3);
        assertEq(uint8(races.getRace(raceId).status), uint8(HamsterRaces.Status.Cancelled));
        _claim(alice);
        _claim(bob);
        assertEq(alice.balance, 100 ether);
        assertEq(bob.balance, 100 ether);
        vm.prank(owner);
        races.reclaimRewards(raceId, owner);
        assertEq(races.rewardLiability(), 0);
    }

    function test_NoLosingBetsReturnsStakesAndUnusedRewards() public {
        _bet(alice, 1, 1 ether);
        _bet(bob, 1, 2 ether);
        _settle(1);
        vm.prank(owner);
        races.reclaimRewards(raceId, carol);
        assertEq(token.balanceOf(carol), REWARD);
        _claim(alice);
        _claim(bob);
        assertEq(alice.balance, 100 ether);
        assertEq(bob.balance, 100 ether);
        assertEq(address(races).balance, 0);
        _assertSolvent();
    }

    function test_EmptyRaceCanFinalizeAndReturnBudget() public {
        _settle(2);
        vm.prank(owner);
        races.reclaimRewards(raceId, owner);
        assertEq(races.rewardLiability(), 0);
        assertEq(races.ethLiability(), 0);
    }

    function test_ClaimsCanBeDirectedByBettorAndDoNotExpire() public {
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 1 ether);
        _settle(1);
        vm.warp(block.timestamp + 20 * 365 days);
        vm.prank(alice);
        races.claim(raceId, payable(carol));
        vm.prank(bob);
        races.claim(raceId, payable(dave));
        assertEq(carol.balance, 102 ether);
        assertEq(token.balanceOf(dave), REWARD / 2);
        assertEq(alice.balance, 99 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RacesAndTheirEscrowsAreIsolated() public {
        uint256 secondId = _create(keccak256("second race"), 2, 2 * REWARD);
        _bet(alice, 1, 2 ether);
        _bet(bob, 2, 3 ether);
        vm.prank(carol);
        races.placeBet{value: 7 ether}(secondId, 2);
        _settle(1);
        _claim(alice);
        _claim(bob);
        assertEq(address(races).balance, 7 ether);
        // Bob's 3 of 5 ETH lost earns 600; the first race's unused 400 waits for its sponsor.
        assertEq(token.balanceOf(bob), 600 ether);
        assertEq(token.balanceOf(address(races)), 2 * REWARD + 400 ether);
        vm.warp(closesAt + races.RESULT_WINDOW());
        races.cancelRace(secondId);
        vm.prank(carol);
        races.claim(secondId, payable(carol));
        vm.prank(owner);
        races.reclaimRewards(secondId, owner);
        vm.prank(owner);
        races.reclaimRewards(raceId, owner);
        assertEq(carol.balance, 100 ether);
        assertEq(address(races).balance, 0);
        assertEq(token.balanceOf(address(races)), 0);
        _assertSolvent();
    }

    function test_DonationsDoNotChangeEntitlements() public {
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 2 ether);
        token.transfer(address(races), 11 ether);
        // Model forced ETH without using SELFDESTRUCT in any delivered contract.
        vm.deal(address(races), address(races).balance + 5 ether);
        _settle(1);
        (uint256 ethAmount,) = _claim(alice);
        (, uint256 reward) = _claim(bob);
        assertEq(ethAmount, 3 ether);
        assertEq(reward, REWARD * 2 / 3);
        vm.warp(closesAt + races.RESULT_WINDOW());
        vm.prank(owner);
        races.reclaimRewards(raceId, owner);
        assertEq(address(races).balance, 5 ether);
        assertEq(token.balanceOf(address(races)), 11 ether);
        assertEq(races.ethLiability(), 0);
        assertEq(races.rewardLiability(), 0);
        _assertSolvent();
    }
}
