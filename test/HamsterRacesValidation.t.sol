// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RaceTestBase} from "./helpers/RaceTestBase.sol";
import {HamsterRaces} from "../src/HamsterRaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract HamsterRacesValidationTest is RaceTestBase {
    function test_DeploymentRequiresExplicitNonzeroOwnerAndToken() public {
        vm.expectRevert(HamsterRaces.InvalidToken.selector);
        new HamsterRaces(IERC20(address(0)), owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new HamsterRaces(token, address(0));
        assertEq(races.owner(), owner);
        assertEq(address(races.hamster()), address(token));
    }

    function test_ReporterMustBeConfiguredByOwnerBeforeCreation() public {
        HamsterRaces fresh = new HamsterRaces(token, owner);
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.ReporterNotConfigured.selector);
        fresh.createRace(keccak256("unconfigured"), 2, closesAt, REWARD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setResultReporter(alice);
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.InvalidReporter.selector);
        fresh.setResultReporter(address(0));
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.InvalidReporter.selector);
        fresh.setResultReporter(address(fresh));
        vm.startPrank(owner);
        fresh.setResultReporter(reporter);
        token.approve(address(fresh), REWARD);
        fresh.createRace(keccak256("configured"), 2, closesAt, REWARD);
        vm.stopPrank();
        assertEq(fresh.getRace(1).reporter, reporter);
    }

    function test_ConstructorNeedsNoExternalCodeButFirstUseChecksToken() public {
        HamsterRaces fresh = new HamsterRaces(IERC20(alice), owner);
        vm.startPrank(owner);
        fresh.setResultReporter(reporter);
        vm.expectRevert(HamsterRaces.InvalidToken.selector);
        fresh.createRace(keccak256("invalid token"), 2, closesAt, REWARD);
        vm.stopPrank();
        assertEq(fresh.raceCount(), 0);
    }

    function test_CreationRejectsUnauthorizedInvalidDuplicateAndUnfundedRaces() public {
        bytes32 ref = keccak256("new race");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        races.createRace(ref, 2, closesAt, REWARD);
        vm.startPrank(owner);
        vm.expectRevert(HamsterRaces.InvalidReference.selector);
        races.createRace(bytes32(0), 2, closesAt, REWARD);
        vm.expectRevert(HamsterRaces.DuplicateReference.selector);
        races.createRace(keccak256("race one"), 2, closesAt, REWARD);
        vm.expectRevert(HamsterRaces.InvalidHamsterCount.selector);
        races.createRace(ref, 1, closesAt, REWARD);
        vm.expectRevert(HamsterRaces.InvalidHamsterCount.selector);
        races.createRace(ref, 17, closesAt, REWARD);
        vm.expectRevert(HamsterRaces.InvalidDeadline.selector);
        races.createRace(ref, 2, uint64(block.timestamp), REWARD);
        vm.expectRevert(HamsterRaces.InvalidDeadline.selector);
        races.createRace(ref, 2, uint64(block.timestamp + 7 days + 1), REWARD);
        vm.expectRevert(HamsterRaces.InvalidDeadline.selector);
        races.createRace(ref, 2, type(uint64).max, REWARD);
        vm.expectRevert(HamsterRaces.InvalidRewardBudget.selector);
        races.createRace(ref, 2, closesAt, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(races), 0, REWARD)
        );
        races.createRace(ref, 2, closesAt, REWARD);
        vm.stopPrank();
        assertEq(races.raceCount(), 1);
        assertEq(races.raceIds(ref), 0);
        assertEq(races.rewardLiability(), REWARD);
    }

    function test_MaximumEntryWindowAndHamsterCountAccepted() public {
        closesAt = uint64(block.timestamp + races.MAX_ENTRY_WINDOW());
        uint256 id = _create(keccak256("maximums"), races.MAX_HAMSTERS(), REWARD);
        assertEq(races.getRace(id).hamsterCount, 16);
    }

    function test_RejectsUnknownRaceEverywhere() public {
        vm.expectRevert(HamsterRaces.UnknownRace.selector);
        races.getRace(0);
        vm.expectRevert(HamsterRaces.UnknownRace.selector);
        races.placeBet(99, 1);
        vm.expectRevert(HamsterRaces.UnknownRace.selector);
        races.reportResult(99, 1);
        vm.expectRevert(HamsterRaces.UnknownRace.selector);
        races.cancelRace(99);
        vm.expectRevert(HamsterRaces.UnknownRace.selector);
        races.claim(99, payable(alice));
        vm.expectRevert(HamsterRaces.UnknownRace.selector);
        races.reclaimRewards(99, alice);
    }

    function test_RejectsZeroInvalidAndDuplicateBets() public {
        vm.startPrank(alice);
        vm.expectRevert(HamsterRaces.ZeroStake.selector);
        races.placeBet(raceId, 1);
        vm.expectRevert(HamsterRaces.InvalidHamster.selector);
        races.placeBet{value: 1}(raceId, 0);
        vm.expectRevert(HamsterRaces.InvalidHamster.selector);
        races.placeBet{value: 1}(raceId, 4);
        races.placeBet{value: 1 ether}(raceId, 1);
        vm.expectRevert(HamsterRaces.AlreadyBet.selector);
        races.placeBet{value: 1 ether}(raceId, 2);
        vm.stopPrank();
        assertEq(races.getRace(raceId).totalStaked, 1 ether);
        assertEq(alice.balance, 99 ether);
        assertEq(races.stakes(raceId, 2), 0);
    }

    function test_EntryClosesExactlyAtDeadlineAndResultCanThenSettle() public {
        vm.warp(closesAt - 1);
        _bet(alice, 1, 1);
        vm.warp(closesAt);
        vm.prank(bob);
        vm.expectRevert(HamsterRaces.BettingClosed.selector);
        races.placeBet{value: 1}(raceId, 2);
        vm.prank(reporter);
        races.reportResult(raceId, 1);
    }

    function test_ResultRejectsUnauthorizedEarlyInvalidLateAndDuplicateCalls() public {
        _bet(alice, 1, 1 ether);
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.NotReporter.selector);
        races.reportResult(raceId, 1);
        vm.prank(reporter);
        vm.expectRevert(HamsterRaces.BettingStillOpen.selector);
        races.reportResult(raceId, 1);
        vm.warp(closesAt);
        vm.startPrank(reporter);
        vm.expectRevert(HamsterRaces.InvalidHamster.selector);
        races.reportResult(raceId, 0);
        vm.expectRevert(HamsterRaces.InvalidHamster.selector);
        races.reportResult(raceId, 4);
        vm.warp(closesAt + races.RESULT_WINDOW());
        vm.expectRevert(HamsterRaces.ResultDeadlinePassed.selector);
        races.reportResult(raceId, 1);
        vm.stopPrank();
        assertEq(uint8(races.getRace(raceId).status), uint8(HamsterRaces.Status.Open));
        assertEq(races.getRace(raceId).winner, 0);
        races.cancelRace(raceId);
        vm.prank(reporter);
        vm.expectRevert(HamsterRaces.RaceNotOpen.selector);
        races.reportResult(raceId, 1);
        _claim(alice);
        assertEq(alice.balance, 100 ether);
    }

    function test_CannotAlterSettledRaceOrCancelEarlyWithoutReporter() public {
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.CancellationNotAllowed.selector);
        races.cancelRace(raceId);
        _bet(alice, 1, 1 ether);
        _settle(1);
        vm.prank(reporter);
        vm.expectRevert(HamsterRaces.RaceNotOpen.selector);
        races.reportResult(raceId, 2);
        vm.prank(reporter);
        vm.expectRevert(HamsterRaces.RaceNotOpen.selector);
        races.cancelRace(raceId);
        vm.prank(bob);
        vm.expectRevert(HamsterRaces.RaceNotOpen.selector);
        races.placeBet{value: 1}(raceId, 2);
    }

    function test_ClaimsRejectEarlyMissingDuplicateAndInvalidRecipient() public {
        _bet(alice, 1, 1 ether);
        vm.prank(alice);
        vm.expectRevert(HamsterRaces.RaceNotFinal.selector);
        races.claim(raceId, payable(alice));
        _settle(1);
        vm.prank(bob);
        vm.expectRevert(HamsterRaces.NoBet.selector);
        races.claim(raceId, payable(bob));
        vm.startPrank(alice);
        vm.expectRevert(HamsterRaces.InvalidRecipient.selector);
        races.claim(raceId, payable(address(0)));
        vm.expectRevert(HamsterRaces.InvalidRecipient.selector);
        races.claim(raceId, payable(address(races)));
        races.claim(raceId, payable(alice));
        vm.expectRevert(HamsterRaces.AlreadyClaimed.selector);
        races.claim(raceId, payable(alice));
        vm.stopPrank();
        assertEq(alice.balance, 100 ether);
    }

    function test_SponsorCannotTakeActiveOrOwedRewardsAndCannotReclaimTwice() public {
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.RaceNotFinal.selector);
        races.reclaimRewards(raceId, owner);
        _bet(alice, 1, 1 ether);
        _bet(bob, 2, 1 ether);
        _settle(1);
        vm.prank(owner);
        vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
        races.reclaimRewards(raceId, owner);

        closesAt = uint64(block.timestamp + 1 hours);
        uint256 emptyId = _create(keccak256("empty"), 2, REWARD);
        vm.prank(reporter);
        races.cancelRace(emptyId);
        vm.prank(alice);
        vm.expectRevert(HamsterRaces.NotSponsor.selector);
        races.reclaimRewards(emptyId, alice);
        vm.startPrank(owner);
        vm.expectRevert(HamsterRaces.InvalidRecipient.selector);
        races.reclaimRewards(emptyId, address(0));
        races.reclaimRewards(emptyId, owner);
        vm.expectRevert(HamsterRaces.NoRefundableRewards.selector);
        races.reclaimRewards(emptyId, owner);
        vm.stopPrank();
        _assertSolvent();
    }

    function test_ReporterRotationAndOwnershipChangesNeverRewriteExistingTerms() public {
        _bet(alice, 1, 1 ether);
        vm.startPrank(owner);
        races.setResultReporter(dave);
        races.transferOwnership(carol);
        vm.stopPrank();
        assertEq(races.owner(), owner);
        assertEq(races.pendingOwner(), carol);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        races.acceptOwnership();
        vm.prank(carol);
        races.acceptOwnership();
        assertEq(races.owner(), carol);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        races.setResultReporter(owner);
        assertEq(races.getRace(raceId).reporter, reporter);
        assertEq(races.getRace(raceId).sponsor, owner);
        vm.warp(closesAt);
        vm.prank(dave);
        vm.expectRevert(HamsterRaces.NotReporter.selector);
        races.reportResult(raceId, 1);
        vm.prank(reporter);
        races.reportResult(raceId, 1);
        vm.prank(carol);
        vm.expectRevert(HamsterRaces.NotSponsor.selector);
        races.reclaimRewards(raceId, carol);
        vm.prank(owner);
        races.reclaimRewards(raceId, owner);
        _claim(alice);
    }
}
