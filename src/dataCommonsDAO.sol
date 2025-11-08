// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract DataCommonDAO is ReentrancyGuard, Ownable {
    IERC20 public immutable stakedToken; // token staked by user

    uint256 applicationStartTime;
    uint256 applicationEndTime;
    uint256 votingStartTime;
    uint256 votingEndTime;

    // Check the code once, since u said me, that times must not collidde of application time and voting time
    uint256 nextApplicationId;
    bool public resultDeclaredOrNot = false; // To know, when the results are declared

    struct Application {
        uint256 id; // unique id
        address applicant; // address
        string ipfsURI; // IPFS link to full application JSON
        uint256 yesWeight; // total yesses in favour
        uint256 noWeight; // total nos against
        bool exists; // if application exists (I am putting this, in case, if user withdraws its application..)
        bool approved; //  if approved or not
        uint256 yieldShareBasisPoints; // share of it
    }

    mapping(uint256 => Application) public applications;
    uint256[] public applicationIds; // List of all submitted application IDs
    mapping(address => uint256) public staked; //User -> How much. stacked
    address[] public stakers; // List of all stakers
    mapping(address => bool) private isStaker; // staker or not
    mapping(address => uint256) public snapshotBalance; // Voting power per user
    uint256 public totalSnapshotVotingPower; // Total voting power

    // Vote tracking
    mapping(uint256 => mapping(address => bool)) public hasVoted; // appId => voter adddress => voted or not
    // means, has this paritcular application id, been voted by this address or not

    // Results
    uint256[] public approvedApplicationIds; // List of approved application IDs
    uint256 public totalApprovedYesWeight; // Sum of yesWeight for all approved apps

    constructor(IERC20 _stakedToken) {
        stackedToken = _stakedToken;
        nextApplicationId = 1;
    }

    // EVENTS
    event applicationTimeSet(uint256 startTime, uint256 endTime);
    event votingTimeSet(uint256 startTime, uint256 endTime);
    event VotingStarted(uint256 timestamp, uint256 totalVotingPower);
    event amountDeposited(address indexed staker, uint256 amount);
    event withdrawn(address indexed staker, uint256 amount);
    event voted(
        uint256 indexed applicationId,
        address indexed voter,
        bool support,
        uint256 votingPower
    );

    // sabse pehle application time set karna hoga
    // then, voting begins

    // CUSTOM ERRORS
    error InvalidTimeRange();
    error ApplicationAndVotingTimeOverlap();
    error ApplicationPeriodNotOver();
    error VotingPhaseNotSet();
    error IPFSuriCannotBeEmpty();
    error ApplicationDoesNotExist();
    error AmountMustBeGreaterThanZero();
    error TransferFailed(address from, address to, uint256 amount);
    error InsufficientStakedBalance();
    error VotingPhaseNotGoingOn();
    error AlreadyVoted();
    error NoVotingPower();

    function setApplicationRange(
        uint256 _start,
        uint256 _end
    ) external onlyOwner {
        if (_start > _end) {
            revert InvalidTimeRange();
        }
        if (_end > votingStartTime) {
            revert ApplicationAndVotingTimeOverlap();
        }
        applicationStartTime = _start;
        applicationEndTime = _end;

        emit applicationTimeSet(_start, _end);
    }

    function setVotingRange(uint256 _start, uint256 _end) external onlyOwner {
        if (_start > _end) {
            revert InvalidTimeRange();
        }
        if (_start < applicationEndTime) {
            revert ApplicationAndVotingTimeOverlap();
        }
        votingStartTime = _start;
        votingEndTime = _end;
        emit votingTimeSet(_start, _end);
    }

    function startTheVotingNow() external onlyOwner {
        // voting woud be start by owner only
        if (applicationStartTime == 0) {
            revert InvalidTimeRange();
        }
        if (block.timestamp < applicationEndTime) {
            revert ApplicationPeriodNotOver();
        }

        if (votingPhaseStart <= 0) {
            revert VotingPhaseNotSet();
        }

        _snapshotStakes();
        emit VotingStarted(block.timestamp, totalSnapshotVotingPower); //time at which, voting started | total voting power
    }

    // continuously application phase is going on, only we create function, to start voting phase

    modifier applicationPhaseGoingOnOrNot() {
        if (
            applicationStartTime > 0 &&
            block.timestamp >= applicationStartTime &&
            block.timestamp <= applicationEndTime
        ) {
            _;
        } else {
            revert ApplicationPeriodNotOver();
        }
    }

    function submitApplication(
        string calldata _ipfsURI
    ) external applicationPhaseGoingOnOrNot {
        if (_ipfsURI.length == 0) {
            revert IPFSuriCannotBeEmpty();
        }
        uint256 appId = nextApplicationId;
        nextApplicationId++;

        // Check THIS once
        Application memory newApp = Application({
            id: appId,
            applicant: msg.sender,
            ipfsURI: _ipfsURI,
            yesWeight: 0,
            noWeight: 0,
            exists: true,
            approved: false,
            yieldShareBasisPoints: 0
        });
        applicationIds.push(appId);

        // Event emmited has to be written, u write it, am getting confused
    }

    function getApplication(
        uint256 id
    ) external view returns (Application memory) {
        if (application[id].exists) {
            Application memory app = applications[idx];
            return app;
        } else {
            revert ApplicationDoesNotExist();
        }
    }

    function getAllApplicationId() external view returns (uint256[] memory) {
        return applicationIds;
    }

    function depositMoney(uint256 amount) external nonReentrant {
        // money is staked by the msg.sender..most probably
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        if (!stakedToken.transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed(msg.sender, address(this), amount);
        }
        if (!isStaker[msg.sender]) {
            isStaker[msg.sender] = true;
            stakers.push(msg.sender);
        }
        staked[msg.sender] += amount;
        emit amountDeposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        if (staked[msg.sender] < amount) {
            revert InsufficientStakedBalance();
        }
        staked[msg.sender] -= amount;
        if (!stakedToken.transfer(msg.sender, amount)) {
            revert TransferFailed(address(this), msg.sender, amount);
        }
        emit withdrawn(msg.sender, amount);
    }

    // Notes to understand the snapshot part

    // Now we will write the codes , for snapshot functions, which are, used to snapshot staker balances
    // Called when voting starts. Freezes voting power for the round.
    // In voting, not everyone has same power
    // more the amount, more the votingg power.
    // So when the voting starts, we freeze the voting power, in order to avoid problems in votings.

    function _snapshotStakes() internal {
        uint256 total = 0;

        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            uint256 balance = staker[staker];
            snapshotBalance[staker] = balance;
            total += balance;
        }
        totalSnapshotVotingPower = total;
    }

    modifier inVotingPhase() {
        if (
            votingStartTime > 0 &&
            block.timestamp >= votingStartTime &&
            block.timestamp <= votingEndTime
        ) {
            _;
        } else {
            revert VotingPhaseNotGoingOn();
        }
    }

    function vote(uint256 applicationId, bool support) external inVotingPhase {
        if (!applications[applicationId].exists) {
            revert ApplicationDoesNotExist();
        }
        if (hasVoted[applicationId][msg.sender]) {
            revert AlreadyVoted();
        }
        uint256 votingPower = snapshotBalance[msg.sender];
        if (votingPower == 0) {
            revert NoVotingPower();
        }
        if (support) {
            applications[applicationId].yesWeight += votingPower;
        } else {
            applications[applicationId].noWeight += votingPower;
        }
        emit voted(applicationId, msg.sender, support, votingPower);
    }

    //  RESULTS

    // GENERATED BY AI(COMMENTS ONLY)(For you to understand the logic we would be applying for calculating results)
    /**
     * @notice Finalize voting results and calculate proportional yield shares
     * @dev Called by owner after voting ends. Implements Method A allocation.
     *
     * LOGIC:
     * 1. Approve all applications where yesWeight > noWeight
     * 2. Calculate total YES weight from all approved apps
     * 3. Each approved app gets: (app.yesWeight / totalApprovedYesWeight) * 100%
     * 4. Store shares in basis points (10000 = 100%)
     *
     * EXAMPLE:
     * - App 1: 1000 YES → 50% share (5000 basis points)
     * - App 2: 600 YES → 30% share (3000 basis points)
     * - App 3: 400 YES → 20% share (2000 basis points)
     * - Total: 2000 YES votes = 100% of yield
     */
}
