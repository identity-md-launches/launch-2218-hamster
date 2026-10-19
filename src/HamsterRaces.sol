// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Bet ETH on externally run hamster races; losing bets share prefunded HAMSTER rewards.
/// @dev A trusted reporter attests real race outcomes. This contract does not generate randomness.
///      The reporter, sponsor, deadlines, and reward budget are fixed for each race before entry.
contract HamsterRaces is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant MIN_HAMSTERS = 2;
    uint8 public constant MAX_HAMSTERS = 16;
    uint64 public constant MAX_ENTRY_WINDOW = 7 days;
    uint64 public constant RESULT_WINDOW = 1 days;

    enum Status {
        None,
        Open,
        Settled,
        Cancelled
    }

    enum CancellationReason {
        Reporter,
        Timeout,
        NoWinningBets
    }

    struct Race {
        bytes32 raceReference;
        address reporter;
        address sponsor;
        uint64 closesAt;
        uint64 resolveBy;
        uint8 hamsterCount;
        uint8 winner;
        Status status;
        uint256 totalStaked;
        uint256 rewardBudget;
        uint256 ethRemaining;
        uint256 rewardsRemaining;
        uint256 winnerStakeRemaining;
        uint256 loserStakeRemaining;
    }

    struct Bet {
        uint256 amount;
        uint8 hamster;
        bool claimed;
    }

    IERC20 public immutable hamster;
    address public resultReporter;
    uint256 public raceCount;
    uint256 public ethLiability;
    uint256 public rewardLiability;
    mapping(uint256 => Race) private _races;
    mapping(bytes32 => uint256) public raceIds;
    mapping(uint256 => mapping(address => Bet)) public bets;
    mapping(uint256 => mapping(uint8 => uint256)) public stakes;

    error InvalidToken();
    error ReporterNotConfigured();
    error InvalidReporter();
    error InvalidReference();
    error DuplicateReference();
    error InvalidHamsterCount();
    error InvalidDeadline();
    error InvalidRewardBudget();
    error IncorrectRewardFunding();
    error UnknownRace();
    error RaceNotOpen();
    error BettingClosed();
    error BettingStillOpen();
    error InvalidHamster();
    error ZeroStake();
    error AlreadyBet();
    error NotReporter();
    error ResultDeadlinePassed();
    error CancellationNotAllowed();
    error RaceNotFinal();
    error NoBet();
    error AlreadyClaimed();
    error InvalidRecipient();
    error NativeTransferFailed();
    error NotSponsor();
    error NoRefundableRewards();

    event ResultReporterSet(address indexed previousReporter, address indexed newReporter);
    event RaceCreated(
        uint256 indexed raceId,
        bytes32 indexed raceReference,
        address indexed sponsor,
        address reporter,
        uint8 hamsterCount,
        uint64 closesAt,
        uint64 resolveBy,
        uint256 rewardBudget
    );
    event BetPlaced(uint256 indexed raceId, address indexed bettor, uint8 indexed hamster, uint256 amount);
    event ResultReported(uint256 indexed raceId, uint8 indexed winner);
    event RaceCancelled(uint256 indexed raceId, CancellationReason reason);
    event Claimed(
        uint256 indexed raceId,
        address indexed bettor,
        address indexed recipient,
        uint256 ethAmount,
        uint256 hamsterAmount
    );
    event RewardsReclaimed(uint256 indexed raceId, address indexed recipient, uint256 amount);

    /// @param hamster_ The HAMSTER token deployed for this launch.
    /// @param owner_ The launch owner's address, supplied explicitly; never inferred from the factory.
    /// @dev No external calls or allocations occur during construction.
    constructor(IERC20 hamster_, address owner_) Ownable(owner_) {
        if (address(hamster_) == address(0)) revert InvalidToken();
        hamster = hamster_;
    }

    /// @notice Configure the trusted result reporter for future races only.
    function setResultReporter(address reporter) external onlyOwner {
        if (reporter == address(0) || reporter == address(this)) revert InvalidReporter();
        emit ResultReporterSet(resultReporter, reporter);
        resultReporter = reporter;
    }

    /// @notice Create a race and escrow its complete reward budget from the owner calling this function.
    /// @dev Approve exactly rewardBudget HAMSTER first. Hamster numbers run from 1 to hamsterCount.
    ///      raceReference identifies the external event and its published rules/hamster numbering.
    function createRace(bytes32 raceReference, uint8 hamsterCount, uint64 closesAt, uint256 rewardBudget)
        external
        nonReentrant
        onlyOwner
        returns (uint256 raceId)
    {
        address reporter = resultReporter;
        if (reporter == address(0)) revert ReporterNotConfigured();
        if (raceReference == bytes32(0)) revert InvalidReference();
        if (raceIds[raceReference] != 0) revert DuplicateReference();
        if (hamsterCount < MIN_HAMSTERS || hamsterCount > MAX_HAMSTERS) revert InvalidHamsterCount();
        if (
            closesAt <= block.timestamp || uint256(closesAt) > block.timestamp + MAX_ENTRY_WINDOW
                || closesAt > type(uint64).max - RESULT_WINDOW
        ) revert InvalidDeadline();
        if (rewardBudget == 0) revert InvalidRewardBudget();
        if (address(hamster).code.length == 0) revert InvalidToken();

        raceId = ++raceCount;
        raceIds[raceReference] = raceId;
        Race storage race = _races[raceId];
        race.raceReference = raceReference;
        race.reporter = reporter;
        race.sponsor = msg.sender;
        race.closesAt = closesAt;
        race.resolveBy = closesAt + RESULT_WINDOW;
        race.hamsterCount = hamsterCount;
        race.status = Status.Open;
        race.rewardBudget = rewardBudget;
        race.rewardsRemaining = rewardBudget;
        rewardLiability += rewardBudget;

        uint256 beforeBalance = hamster.balanceOf(address(this));
        hamster.safeTransferFrom(msg.sender, address(this), rewardBudget);
        if (hamster.balanceOf(address(this)) != beforeBalance + rewardBudget) revert IncorrectRewardFunding();

        emit RaceCreated(
            raceId, raceReference, msg.sender, reporter, hamsterCount, closesAt, race.resolveBy, rewardBudget
        );
    }

    /// @notice Place one immutable bet per address per race before the entry deadline.
    function placeBet(uint256 raceId, uint8 hamsterNumber) external payable nonReentrant {
        Race storage race = _openRace(raceId);
        if (block.timestamp >= race.closesAt) revert BettingClosed();
        if (hamsterNumber == 0 || hamsterNumber > race.hamsterCount) revert InvalidHamster();
        if (msg.value == 0) revert ZeroStake();
        if (bets[raceId][msg.sender].amount != 0) revert AlreadyBet();

        bets[raceId][msg.sender] = Bet(msg.value, hamsterNumber, false);
        stakes[raceId][hamsterNumber] += msg.value;
        race.totalStaked += msg.value;
        race.ethRemaining += msg.value;
        ethLiability += msg.value;
        emit BetPlaced(raceId, msg.sender, hamsterNumber, msg.value);
    }

    /// @notice The race's snapshotted reporter submits its one final, externally observed winner.
    /// @dev Requires closesAt <= now < resolveBy. No external payment occurs during settlement.
    ///      With no bets on the winning hamster, the race is void and every bettor gets a refund.
    function reportResult(uint256 raceId, uint8 winner) external nonReentrant {
        Race storage race = _openRace(raceId);
        if (msg.sender != race.reporter) revert NotReporter();
        if (block.timestamp < race.closesAt) revert BettingStillOpen();
        if (block.timestamp >= race.resolveBy) revert ResultDeadlinePassed();
        if (winner == 0 || winner > race.hamsterCount) revert InvalidHamster();

        race.winner = winner;
        emit ResultReported(raceId, winner);
        uint256 winningStake = stakes[raceId][winner];
        if (winningStake == 0) {
            _cancel(raceId, race, CancellationReason.NoWinningBets);
        } else {
            race.status = Status.Settled;
            race.winnerStakeRemaining = winningStake;
            race.loserStakeRemaining = race.totalStaked - winningStake;
        }
    }

    /// @notice The reporter may void a race; anyone may void it at/after the result deadline.
    /// @dev Refunds and unused rewards are withdrawn separately, without a participant loop.
    function cancelRace(uint256 raceId) external nonReentrant {
        Race storage race = _openRace(raceId);
        bool timedOut = block.timestamp >= race.resolveBy;
        if (!timedOut && msg.sender != race.reporter) revert CancellationNotAllowed();
        _cancel(raceId, race, timedOut ? CancellationReason.Timeout : CancellationReason.Reporter);
    }

    /// @notice Claim your refund, winning ETH payout, or losing HAMSTER reward to your chosen recipient.
    /// @dev Each share uses the original pool/weight. Its final claimant receives any rounding dust.
    ///      A failed recipient/token transfer rolls back the claim, allowing a retry to another address.
    function claim(uint256 raceId, address payable recipient)
        external
        nonReentrant
        returns (uint256 ethAmount, uint256 hamsterAmount)
    {
        _checkRecipient(recipient);
        Race storage race = _finalRace(raceId);
        Bet storage bet = bets[raceId][msg.sender];
        if (bet.amount == 0) revert NoBet();
        if (bet.claimed) revert AlreadyClaimed();
        bet.claimed = true;

        if (race.status == Status.Cancelled) {
            ethAmount = bet.amount;
        } else if (bet.hamster == race.winner) {
            ethAmount = bet.amount == race.winnerStakeRemaining
                ? race.ethRemaining
                : Math.mulDiv(race.totalStaked, bet.amount, stakes[raceId][race.winner]);
            race.winnerStakeRemaining -= bet.amount;
        } else {
            hamsterAmount = bet.amount == race.loserStakeRemaining
                ? race.rewardsRemaining
                : Math.mulDiv(race.rewardBudget, bet.amount, race.totalStaked - stakes[raceId][race.winner]);
            race.loserStakeRemaining -= bet.amount;
        }

        race.ethRemaining -= ethAmount;
        race.rewardsRemaining -= hamsterAmount;
        ethLiability -= ethAmount;
        rewardLiability -= hamsterAmount;
        emit Claimed(raceId, msg.sender, recipient, ethAmount, hamsterAmount);
        if (hamsterAmount != 0) hamster.safeTransfer(recipient, hamsterAmount);
        if (ethAmount != 0) {
            (bool success,) = recipient.call{value: ethAmount}("");
            if (!success) revert NativeTransferFailed();
        }
    }

    /// @notice Only the original sponsor can reclaim rewards when the race is void or has no losers.
    /// @dev There is no sweep of bettor claims, no claim expiry, and no withdrawal of active budgets.
    function reclaimRewards(uint256 raceId, address recipient) external nonReentrant returns (uint256 amount) {
        _checkRecipient(recipient);
        Race storage race = _finalRace(raceId);
        if (msg.sender != race.sponsor) revert NotSponsor();
        if (race.status == Status.Settled && race.totalStaked != stakes[raceId][race.winner]) {
            revert NoRefundableRewards();
        }
        amount = race.rewardsRemaining;
        if (amount == 0) revert NoRefundableRewards();
        race.rewardsRemaining = 0;
        rewardLiability -= amount;
        emit RewardsReclaimed(raceId, recipient, amount);
        hamster.safeTransfer(recipient, amount);
    }

    function getRace(uint256 raceId) external view returns (Race memory) {
        return _existingRace(raceId);
    }

    function _existingRace(uint256 raceId) private view returns (Race storage race) {
        race = _races[raceId];
        if (race.status == Status.None) revert UnknownRace();
    }

    function _openRace(uint256 raceId) private view returns (Race storage race) {
        race = _existingRace(raceId);
        if (race.status != Status.Open) revert RaceNotOpen();
    }

    function _finalRace(uint256 raceId) private view returns (Race storage race) {
        race = _existingRace(raceId);
        if (race.status == Status.Open) revert RaceNotFinal();
    }

    function _cancel(uint256 raceId, Race storage race, CancellationReason reason) private {
        race.status = Status.Cancelled;
        emit RaceCancelled(raceId, reason);
    }

    function _checkRecipient(address recipient) private view {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
    }
}
