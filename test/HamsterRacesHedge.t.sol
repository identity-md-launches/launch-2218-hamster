// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RaceTestBase} from "./helpers/RaceTestBase.sol";
import {HamsterRaces} from "../src/HamsterRaces.sol";

/// @dev A bettor covering every hamster from one address each loses no ETH. Losers share only
///      R * L / T, so such a hedge never captures the whole budget, and the sponsor recovers the rest.
contract HamsterRacesHedgeTest is RaceTestBase {
    function test_SoloHedgeCannotTakeTheWholeBudgetAndSponsorRecoversTheRest() public {
        _bet(alice, 1, 1);
        _bet(bob, 2, 1);
        _bet(carol, 3, 1);
        _settle(2);
        (uint256 ethBack,) = _claim(bob);
        (, uint256 r1) = _claim(alice);
        (, uint256 r3) = _claim(carol);
        assertEq(ethBack, 3);
        assertEq(r1 + r3, REWARD * 2 / 3);
        assertLt(r1 + r3, REWARD);

        // The winning side's share is the sponsor's, but only once the result window ends.
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
        races.reclaimRewards(raceId, owner);
        vm.warp(closesAt + races.RESULT_WINDOW() - 1);
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
        races.reclaimRewards(raceId, owner);
        vm.warp(closesAt + races.RESULT_WINDOW());
        vm.prank(alice);
        vm.expectRevert(HamsterRaces.NotSponsor.selector);
        races.reclaimRewards(raceId, alice);
        vm.startPrank(owner);
        assertEq(races.reclaimRewards(raceId, owner), REWARD - REWARD * 2 / 3);
        vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
        races.reclaimRewards(raceId, owner);
        vm.stopPrank();
        assertEq(races.rewardLiability(), 0);
        assertEq(token.balanceOf(address(races)), 0);
        _assertSolvent();
    }

    function test_SponsorReclaimNeverTouchesUnclaimedLossRewards() public {
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 1 ether);
        _bet(carol, 3, 2 ether);
        _settle(1);
        vm.warp(closesAt + races.RESULT_WINDOW());
        vm.prank(owner);
        assertEq(races.reclaimRewards(raceId, owner), 250 ether);
        assertEq(races.rewardLiability(), 750 ether);
        (, uint256 bobReward) = _claim(bob);
        (, uint256 carolReward) = _claim(carol);
        assertEq(bobReward, 250 ether);
        assertEq(carolReward, 500 ether);
        (uint256 aliceEth,) = _claim(alice);
        assertEq(aliceEth, 4 ether);
        assertEq(races.rewardLiability(), 0);
        _assertSolvent();
    }

    /// @dev An honest loser's reward per losing wei is R / T whatever a hedger does; a hedger adding x on
    ///      every hamster can only dilute it through T, and its own losing addresses earn the same rate.
    function testFuzz_LossRewardNeverExceedsBudgetPerTotalStake(uint96 h, uint96 a, uint96 b, uint8 w) public {
        uint256 hedge = bound(uint256(h), 1, 30 ether);
        uint256 aStake = bound(uint256(a), 1, 30 ether);
        uint256 bStake = bound(uint256(b), 1, 30 ether);
        uint8 winner = uint8(bound(w, 1, 3));
        address[3] memory hedgers = [makeAddr("h1"), makeAddr("h2"), makeAddr("h3")];
        for (uint8 i; i < 3; ++i) {
            vm.deal(hedgers[i], hedge);
            vm.prank(hedgers[i]);
            races.placeBet{value: hedge}(raceId, i + 1);
        }
        _bet(alice, 1, aStake);
        _bet(bob, 2, bStake);
        uint256 total = 3 * hedge + aStake + bStake;
        _settle(winner);

        uint256 hedgeEth;
        uint256 hedgeReward;
        for (uint8 i; i < 3; ++i) {
            vm.prank(hedgers[i]);
            (uint256 e, uint256 r) = races.claim(raceId, payable(hedgers[i]));
            hedgeEth += e;
            hedgeReward += r;
        }
        (, uint256 aliceReward) = _claim(alice);
        (, uint256 bobReward) = _claim(bob);
        uint256 losing = total - races.stakes(raceId, winner);
        assertEq(hedgeReward + aliceReward + bobReward, REWARD * losing / total);
        assertLe(hedgeReward, REWARD * 2 * hedge / total + 1);
        assertLt(hedgeReward, REWARD);
        if (winner != 1) assertGe(aliceReward + 1, REWARD * aStake / total);
        if (winner != 2) assertGe(bobReward + 1, REWARD * bStake / total);
        assertLe(hedgeEth, total);
        _assertSolvent();
    }
}
