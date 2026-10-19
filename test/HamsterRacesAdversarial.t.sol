// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RaceTestBase} from "./helpers/RaceTestBase.sol";
import {HamsterRaces} from "../src/HamsterRaces.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ClaimReceiver {
    HamsterRaces private immutable races;
    uint256 private raceId;
    bool private rejectPayment;
    bool private attemptReentry;
    bool public reentryRejected;
    uint256 public callbacks;

    constructor(HamsterRaces races_) {
        races = races_;
    }

    function enter(uint256 id, uint8 hamsterNumber) external payable {
        raceId = id;
        races.placeBet{value: msg.value}(id, hamsterNumber);
    }

    function configure(bool reject, bool reenter) external {
        rejectPayment = reject;
        attemptReentry = reenter;
    }

    function withdraw(address payable recipient) external {
        races.claim(raceId, recipient);
    }

    receive() external payable {
        require(!rejectPayment, "recipient rejects ETH");
        ++callbacks;
        if (attemptReentry) {
            (bool success, bytes memory reason) =
                address(races).call(abi.encodeCall(races.claim, (raceId, payable(address(this)))));
            reentryRejected = !success
                && keccak256(reason)
                    == keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        }
    }
}

/// @dev Deliberately incompatible test token, never a deployment parameter for the real application.
contract ShortFundingToken is ERC20 {
    constructor(address recipient) ERC20("Test short funding", "TEST") {
        _mint(recipient, 100 ether);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, value);
        }
    }
}

contract HamsterRacesAdversarialTest is RaceTestBase {
    function test_ReentrantWinnerCannotClaimTwice() public {
        ClaimReceiver receiver = new ClaimReceiver(races);
        vm.deal(address(this), 1 ether);
        receiver.enter{value: 1 ether}(raceId, 1);
        _bet(bob, 2, 2 ether);
        _settle(1);
        receiver.configure(false, true);
        receiver.withdraw(payable(address(receiver)));
        assertTrue(receiver.reentryRejected());
        assertEq(receiver.callbacks(), 1);
        assertEq(address(receiver).balance, 3 ether);
        assertEq(races.ethLiability(), 0);
        _claim(bob);
        _assertSolvent();
    }

    function test_RevertingRecipientDoesNotBlockSettlementOrOtherClaims() public {
        ClaimReceiver receiver = new ClaimReceiver(races);
        vm.deal(address(this), 1 ether);
        receiver.enter{value: 1 ether}(raceId, 1);
        receiver.configure(true, false);
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 2 ether);
        _settle(1);
        vm.expectRevert(HamsterRaces.NativeTransferFailed.selector);
        receiver.withdraw(payable(address(receiver)));
        (,, bool claimed) = races.bets(raceId, address(receiver));
        assertFalse(claimed);
        assertEq(races.ethLiability(), 4 ether);
        assertEq(races.getRace(raceId).winnerStakeRemaining, 2 ether);
        _claim(alice);
        _claim(bob);
        receiver.withdraw(payable(carol));
        assertEq(carol.balance, 102 ether);
        assertEq(alice.balance, 101 ether);
        assertEq(races.ethLiability(), 0);
        _assertSolvent();
    }

    function test_ReentrantRefundCannotDrainAnotherRace() public {
        ClaimReceiver receiver = new ClaimReceiver(races);
        vm.deal(address(this), 1 ether);
        receiver.enter{value: 1 ether}(raceId, 1);
        uint256 second = _create(keccak256("unrelated escrow"), 2, REWARD);
        vm.prank(alice);
        races.placeBet{value: 10 ether}(second, 1);
        vm.prank(reporter);
        races.cancelRace(raceId);
        receiver.configure(false, true);
        receiver.withdraw(payable(address(receiver)));
        assertTrue(receiver.reentryRejected());
        assertEq(address(receiver).balance, 1 ether);
        assertEq(races.ethLiability(), 10 ether);
        assertEq(races.getRace(second).ethRemaining, 10 ether);
        _assertSolvent();
    }

    function test_FailedTokenPayoutRollsBackAndCanBeRetried() public {
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 1 ether);
        _settle(1);
        vm.mockCall(address(token), abi.encodeCall(IERC20.transfer, (bob, REWARD)), abi.encode(false));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        races.claim(raceId, payable(bob));
        (,, bool claimed) = races.bets(raceId, bob);
        assertFalse(claimed);
        assertEq(races.rewardLiability(), REWARD);
        assertEq(races.getRace(raceId).loserStakeRemaining, 1 ether);
        vm.clearMockedCalls();
        _claim(bob);
        assertEq(token.balanceOf(bob), REWARD);
        assertEq(races.rewardLiability(), 0);
        _assertSolvent();
    }

    function test_FailedRewardFundingLeavesNoRaceOrLiability() public {
        vm.startPrank(owner);
        token.approve(address(races), REWARD);
        vm.mockCall(
            address(token), abi.encodeCall(IERC20.transferFrom, (owner, address(races), REWARD)), abi.encode(false)
        );
        bytes32 ref = keccak256("failed funding");
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        races.createRace(ref, 2, closesAt, REWARD);
        vm.clearMockedCalls();
        vm.stopPrank();
        assertEq(races.raceCount(), 1);
        assertEq(races.raceIds(ref), 0);
        assertEq(races.rewardLiability(), REWARD);
        assertEq(token.balanceOf(address(races)), REWARD);
    }

    function test_ShortRewardFundingRevertsAtomically() public {
        ShortFundingToken shortToken = new ShortFundingToken(owner);
        HamsterRaces fresh = new HamsterRaces(shortToken, owner);
        vm.startPrank(owner);
        fresh.setResultReporter(reporter);
        shortToken.approve(address(fresh), 100 ether);
        vm.expectRevert(HamsterRaces.IncorrectRewardFunding.selector);
        fresh.createRace(keccak256("short funding"), 2, closesAt, 100 ether);
        vm.stopPrank();
        assertEq(fresh.raceCount(), 0);
        assertEq(fresh.rewardLiability(), 0);
        assertEq(shortToken.balanceOf(owner), 100 ether);
        assertEq(shortToken.balanceOf(address(fresh)), 0);
    }

    function test_FailedSponsorRefundCanBeRetried() public {
        vm.prank(reporter);
        races.cancelRace(raceId);
        vm.mockCall(address(token), abi.encodeCall(IERC20.transfer, (owner, REWARD)), abi.encode(false));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        races.reclaimRewards(raceId, owner);
        assertEq(races.rewardLiability(), REWARD);
        assertEq(races.getRace(raceId).rewardsRemaining, REWARD);
        vm.clearMockedCalls();
        vm.prank(owner);
        races.reclaimRewards(raceId, owner);
        assertEq(races.rewardLiability(), 0);
        _assertSolvent();
    }

    function test_NativeCurrencyOutsideBetIsRejected() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(races).call{value: 1}("");
        assertFalse(ok);
        assertEq(races.ethLiability(), 0);
    }
}
