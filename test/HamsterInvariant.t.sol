// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterRaces} from "../src/HamsterRaces.sol";

/// @dev Stateful test driver. Roles and funds here are isolated test fixtures, never launch settings.
contract RaceHandler is Test {
    HamsterToken public immutable token;
    HamsterRaces public immutable races;
    address[6] public actors;
    uint256 public depositedEth;
    uint256 public paidEth;
    uint256 public fundedRewards;
    uint256 public paidRewards;
    uint256 public reclaimedRewards;
    uint256 public donatedRewards;

    constructor(HamsterToken token_) {
        token = token_;
        races = new HamsterRaces(token, address(this));
        races.setResultReporter(address(this));
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(0x1000 + i));
        }
    }

    function openRace(uint8 count, uint32 duration, uint96 reward) external {
        if (races.raceCount() >= 8) return;
        uint256 budget = bound(uint256(reward), 1, 10_000 ether);
        if (token.balanceOf(address(this)) < budget) return;
        token.approve(address(races), budget);
        races.createRace(
            keccak256(abi.encode(races.raceCount() + 1)),
            uint8(bound(count, 2, 16)),
            uint64(block.timestamp + bound(duration, 1, 1 days)),
            budget
        );
        fundedRewards += budget;
    }

    function bet(uint256 seed, uint8 actorSeed, uint8 hamsterSeed, uint96 stake) external {
        uint256 id = _id(seed);
        if (id == 0) return;
        HamsterRaces.Race memory race = races.getRace(id);
        if (race.status != HamsterRaces.Status.Open || block.timestamp >= race.closesAt) return;
        address actor = actors[actorSeed % actors.length];
        (uint256 existing,,) = races.bets(id, actor);
        if (existing != 0) return;
        uint256 amount = bound(uint256(stake), 1, 100 ether);
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        races.placeBet{value: amount}(id, uint8(bound(hamsterSeed, 1, race.hamsterCount)));
        depositedEth += amount;
    }

    function advanceTime(uint32 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1, 12 hours));
    }

    function settle(uint256 seed, uint8 winnerSeed) external {
        uint256 id = _id(seed);
        if (id == 0) return;
        HamsterRaces.Race memory race = races.getRace(id);
        if (
            race.status != HamsterRaces.Status.Open || block.timestamp < race.closesAt
                || block.timestamp >= race.resolveBy
        ) return;
        races.reportResult(id, uint8(bound(winnerSeed, 1, race.hamsterCount)));
    }

    function cancel(uint256 seed) external {
        uint256 id = _id(seed);
        if (id != 0 && races.getRace(id).status == HamsterRaces.Status.Open) races.cancelRace(id);
    }

    function claim(uint256 seed, uint8 actorSeed) external {
        uint256 id = _id(seed);
        if (id == 0) return;
        _claim(id, actors[actorSeed % actors.length]);
    }

    function reclaim(uint256 seed) external {
        uint256 id = _id(seed);
        if (id != 0) _reclaim(id);
    }

    function donate(uint96 amountSeed) external {
        uint256 amount = bound(uint256(amountSeed), 0, 100 ether);
        if (token.balanceOf(address(this)) < amount) return;
        token.transfer(address(races), amount);
        donatedRewards += amount;
    }

    /// @dev End each generated sequence by exercising timeout/claims to prove funds remain withdrawable.
    function drainAll() external {
        uint256 count = races.raceCount();
        uint256 latestDeadline = block.timestamp;
        for (uint256 id = 1; id <= count; ++id) {
            uint256 deadline = races.getRace(id).resolveBy;
            if (deadline > latestDeadline) latestDeadline = deadline;
        }
        vm.warp(latestDeadline);
        for (uint256 id = 1; id <= count; ++id) {
            if (races.getRace(id).status == HamsterRaces.Status.Open) {
                vm.prank(actors[0]);
                races.cancelRace(id);
            }
            for (uint256 i; i < actors.length; ++i) {
                _claim(id, actors[i]);
            }
            _reclaim(id);
        }
    }

    function _id(uint256 seed) private view returns (uint256) {
        uint256 count = races.raceCount();
        return count == 0 ? 0 : 1 + seed % count;
    }

    function _claim(uint256 id, address actor) private {
        if (races.getRace(id).status == HamsterRaces.Status.Open) return;
        (uint256 amount,, bool claimed) = races.bets(id, actor);
        if (amount == 0 || claimed) return;
        vm.prank(actor);
        (uint256 ethAmount, uint256 rewardAmount) = races.claim(id, payable(actor));
        paidEth += ethAmount;
        paidRewards += rewardAmount;
    }

    function _reclaim(uint256 id) private {
        HamsterRaces.Race memory race = races.getRace(id);
        if (race.status == HamsterRaces.Status.Open || race.rewardsRemaining == race.lossRewardRemaining) return;
        if (race.status == HamsterRaces.Status.Settled && race.lossRewardPool != 0 && block.timestamp < race.resolveBy) return;
        reclaimedRewards += races.reclaimRewards(id, address(this));
    }
}

contract HamsterInvariantTest is Test {
    HamsterToken internal token;
    HamsterRaces internal races;
    RaceHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new HamsterToken();
        handler = new RaceHandler(token);
        races = handler.races();
        token.transfer(address(handler), 1_000_000 ether);
        handler.openRace(3, 1 hours, 1_000 ether);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = RaceHandler.openRace.selector;
        selectors[1] = RaceHandler.bet.selector;
        selectors[2] = RaceHandler.advanceTime.selector;
        selectors[3] = RaceHandler.settle.selector;
        selectors[4] = RaceHandler.cancel.selector;
        selectors[5] = RaceHandler.claim.selector;
        selectors[6] = RaceHandler.reclaim.selector;
        selectors[7] = RaceHandler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_EscrowsConserveBothAssetsAndSupply() public view {
        uint256 totalEthRemaining;
        uint256 totalRewardsRemaining;
        for (uint256 id = 1; id <= races.raceCount(); ++id) {
            HamsterRaces.Race memory race = races.getRace(id);
            totalEthRemaining += race.ethRemaining;
            totalRewardsRemaining += race.rewardsRemaining;
            assertLe(race.ethRemaining, race.totalStaked);
            assertLe(race.rewardsRemaining, race.rewardBudget);
            assertLe(race.lossRewardRemaining, race.rewardsRemaining);
            assertLe(race.lossRewardRemaining, race.lossRewardPool);
            if (race.status == HamsterRaces.Status.Settled) {
                uint256 losing = race.totalStaked - races.stakes(id, race.winner);
                assertEq(race.lossRewardPool, race.rewardBudget * losing / race.totalStaked);
            }
        }
        assertEq(races.ethLiability(), totalEthRemaining);
        assertEq(races.rewardLiability(), totalRewardsRemaining);
        assertEq(address(races).balance, handler.depositedEth() - handler.paidEth());
        assertEq(address(races).balance, races.ethLiability());
        assertEq(races.rewardLiability(), handler.fundedRewards() - handler.paidRewards() - handler.reclaimedRewards());
        assertEq(token.balanceOf(address(races)), races.rewardLiability() + handler.donatedRewards());

        uint256 accountedTokens =
            token.balanceOf(address(this)) + token.balanceOf(address(handler)) + token.balanceOf(address(races));
        for (uint256 i; i < 6; ++i) {
            accountedTokens += token.balanceOf(handler.actors(i));
        }
        assertEq(accountedTokens, token.totalSupply());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function afterInvariant() public {
        handler.drainAll();
        assertEq(races.ethLiability(), 0);
        assertEq(races.rewardLiability(), 0);
        assertEq(address(races).balance, 0);
        assertEq(token.balanceOf(address(races)), handler.donatedRewards());
        assertEq(handler.depositedEth(), handler.paidEth());
        assertEq(handler.fundedRewards(), handler.paidRewards() + handler.reclaimedRewards());
    }
}
