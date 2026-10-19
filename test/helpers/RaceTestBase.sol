// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterToken} from "../../src/HamsterToken.sol";
import {HamsterRaces} from "../../src/HamsterRaces.sol";

abstract contract RaceTestBase is Test {
    HamsterToken internal token;
    HamsterRaces internal races;
    address internal owner = makeAddr("launch owner");
    address internal reporter = makeAddr("result reporter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    uint64 internal closesAt;
    uint256 internal constant REWARD = 1_000 ether;
    uint256 internal raceId;

    function setUp() public virtual {
        vm.warp(1_000_000);
        token = new HamsterToken();
        races = new HamsterRaces(token, owner);
        token.transfer(owner, 1_000_000 ether);
        vm.prank(owner);
        races.setResultReporter(reporter);
        closesAt = uint64(block.timestamp + 1 hours);
        raceId = _create(keccak256("race one"), 3, REWARD);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dave, 100 ether);
    }

    function _create(bytes32 raceRef, uint8 count, uint256 reward) internal returns (uint256 id) {
        vm.startPrank(owner);
        token.approve(address(races), reward);
        id = races.createRace(raceRef, count, closesAt, reward);
        vm.stopPrank();
    }

    function _bet(address bettor, uint8 hamsterNumber, uint256 amount) internal {
        vm.prank(bettor);
        races.placeBet{value: amount}(raceId, hamsterNumber);
    }

    function _settle(uint8 winner) internal {
        vm.warp(closesAt);
        vm.prank(reporter);
        races.reportResult(raceId, winner);
    }

    function _claim(address bettor) internal returns (uint256 ethAmount, uint256 tokenAmount) {
        vm.prank(bettor);
        return races.claim(raceId, payable(bettor));
    }

    function _assertSolvent() internal view {
        assertGe(address(races).balance, races.ethLiability());
        assertGe(token.balanceOf(address(races)), races.rewardLiability());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
