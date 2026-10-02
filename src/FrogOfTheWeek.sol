// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IFrogsToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Weekly, token-weighted voting with refundable FROGS deposits and no administrator.
/// @dev Deploy with the immutable LaunchToken. Direct token donations are not votes or refundable
/// deposits. Fee-on-transfer and rebasing tokens are unsupported. Amounts are token minor units.
contract FrogOfTheWeek {
    uint256 public constant WEEK_DURATION = 7 days;
    uint256 public constant AGENT_COUNT = 2000;
    uint256 public constant NO_WINNER = AGENT_COUNT;

    IFrogsToken public immutable token;
    uint256 public immutable startTime;
    uint256 public nextWeekToFinalize;
    uint256 public totalLocked;

    struct Week {
        uint256 totalVotes;
        uint256 leader;
        uint256 leadingVotes;
        bool finalized;
        uint256 winner;
    }

    mapping(uint256 week => Week) private weekRecords;
    mapping(uint256 week => uint256[2000]) private votes;
    mapping(uint256 week => mapping(address voter => uint256)) public locked;
    uint256 private entered = 1;

    error InvalidToken();
    error InvalidAgent(uint256 agentId);
    error ZeroAmount();
    error WrongWeek(uint256 expected, uint256 actual);
    error WeekNotEnded(uint256 week);
    error NothingToWithdraw();
    error TokenTransferFailed();
    error UnexpectedTokenBalance();
    error ReentrantCall();

    event Voted(uint256 indexed week, address indexed voter, uint256 indexed agentId, uint256 amount);
    event WeekFinalized(uint256 indexed week, uint256 indexed winner, uint256 winningVotes, uint256 totalVotes);
    event Withdrawn(uint256 indexed week, address indexed voter, uint256 amount);

    /// @param token_ The deployed LaunchToken address, passed as $token by the project factory.
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IFrogsToken(token_);
        startTime = block.timestamp;
    }

    modifier nonReentrant() {
        if (entered != 1) revert ReentrantCall();
        entered = 2;
        _;
        entered = 1;
    }

    /// @notice Zero-based week. A week starts at startTime + week * WEEK_DURATION.
    function currentWeek() public view returns (uint256) {
        return (block.timestamp - startTime) / WEEK_DURATION;
    }

    /// @notice Add a refundable vote for an agent, only in the week the voter intended.
    /// @dev A voter may add votes for multiple agents; no cancellation or reassignment this week.
    function vote(uint256 expectedWeek, uint256 agentId, uint256 amount) external nonReentrant {
        uint256 week = currentWeek();
        if (expectedWeek != week) revert WrongWeek(expectedWeek, week);
        if (agentId >= AGENT_COUNT) revert InvalidAgent(agentId);
        if (amount == 0) revert ZeroAmount();

        Week storage info = weekRecords[week];
        uint256 agentVotes = votes[week][agentId] + amount;
        votes[week][agentId] = agentVotes;
        info.totalVotes += amount;
        if (agentVotes > info.leadingVotes || (agentVotes == info.leadingVotes && agentId < info.leader)) {
            info.leader = agentId;
            info.leadingVotes = agentVotes;
        }
        locked[week][msg.sender] += amount;
        totalLocked += amount;

        uint256 beforeBalance = token.balanceOf(address(this));
        _safeCall(abi.encodeCall(IFrogsToken.transferFrom, (msg.sender, address(this), amount)));
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnexpectedTokenBalance();
        emit Voted(week, msg.sender, agentId, amount);
    }

    /// @notice Record the oldest unfinalized ended week. Anyone may call once per pending week.
    /// @dev Ties go to the lowest agent number. Empty weeks record NO_WINNER, never agent zero.
    /// Work is constant regardless of agents, voters or idle weeks. Future voting never waits on it.
    function finalize() external nonReentrant {
        uint256 week = nextWeekToFinalize;
        if (week >= currentWeek()) revert WeekNotEnded(week);
        Week storage info = weekRecords[week];
        uint256 winner = info.totalVotes == 0 ? NO_WINNER : info.leader;
        info.winner = winner;
        info.finalized = true;
        nextWeekToFinalize = week + 1;
        emit WeekFinalized(week, winner, info.leadingVotes, info.totalVotes);
    }

    /// @notice Withdraw all of your deposits from one ended week, even before finalize is called.
    /// @dev Historic votes and winners remain unchanged. Only the caller's deposit can be withdrawn.
    function withdraw(uint256 week) external nonReentrant {
        if (week >= currentWeek()) revert WeekNotEnded(week);
        uint256 amount = locked[week][msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        locked[week][msg.sender] = 0;
        totalLocked -= amount;

        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(msg.sender);
        _safeCall(abi.encodeCall(IFrogsToken.transfer, (msg.sender, amount)));
        if (
            token.balanceOf(address(this)) + amount != beforeBalance
                || token.balanceOf(msg.sender) != beforeRecipient + amount
        ) revert UnexpectedTokenBalance();
        emit Withdrawn(week, msg.sender, amount);
    }

    /// @notice Stored summary, using NO_WINNER for both empty leaders and unfinalized winners.
    /// Check `finalized` to distinguish a pending result from a finalized empty week.
    function weekInfo(uint256 week)
        external
        view
        returns (uint256 totalVotes, uint256 leader, uint256 leadingVotes, bool finalized, uint256 winner)
    {
        Week storage info = weekRecords[week];
        return (
            info.totalVotes,
            info.totalVotes == 0 ? NO_WINNER : info.leader,
            info.leadingVotes,
            info.finalized,
            info.finalized ? info.winner : NO_WINNER
        );
    }

    /// @notice Historical totals indexed by agent number, independent of withdrawals.
    function getVotes(uint256 week) external view returns (uint256[2000] memory) {
        return votes[week];
    }

    function _safeCall(bytes memory data) private {
        (bool success, bytes memory result) = address(token).call(data);
        if (!success || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TokenTransferFailed();
        }
    }
}
