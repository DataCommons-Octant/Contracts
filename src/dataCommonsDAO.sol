// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {PaymentSplitter} from "../lib/octant-v2-core/src/core/PaymentSplitter.sol";

contract DataCommonsDAO is Ownable, ReentrancyGuard {
    uint16 public constant BASIS_POINTS = 10000; // 100.00%

    enum Phase {
        Idle,
        Application,
        Voting,
        Finalized
    } // governance phases

    /**
     * @notice Struct representing an application submitted by an applicant
     * @param applicant Address of the applicant
     * @param index Numeric index chosen by the applicant
     * @param ipfsUri IPFS URI containing detailed application data
     * @param exists Boolean indicating if the application exists
     */
    struct Application {
        address applicant;
        uint256 index;
        string ipfsUri;
        bool exists;
    }

    // input from voters: list of applicant indices + assigned shares in basis points
    struct VoteSubmission {
        uint256[] indices;
        uint256[] shares; // basis points per index (not required to sum to BASIS_POINTS)
    }

    /**
     * @notice Struct representing a winning application
     * @param index Numeric index of the winning application
     * @param applicant Address of the winning applicant
     * @param normalizedShare Normalized share in basis points (sums to BASIS_POINTS across winners)
     * @param rawScore Aggregated raw score before normalization
     */
    struct Winner {
        uint256 index;
        address applicant;
        uint256 normalizedShare;
        uint256 rawScore;
    }

    // Parameters
    uint256 public applicationStart; // timestamp at which applications open
    uint256 public applicationEnd; // timestamp at which applications close
    uint256 public votingEnd; // timestamp at which voting ends
    uint256 public maxWinners; // max number of winners to select
    uint256 public maxApplications; // max number of applications (0 = unlimited)
    address private immutable paymentSplitterAddress; // address of the payment splitter contract

    Phase public phase;

    mapping(uint256 => Application) public applications;
    uint256 public applicationCount;

    mapping(address => bool) public isApplicantRegistered; // Track if an address is registered as applicant (prevents duplicate indexed entries)
    mapping(uint256 => uint256) public aggregatedScores; // Votes: per applicant index aggregated from all voters (raw score)
    mapping(address => bool) public hasVoted; // Track whether a voter has cast their vote for this epoch
    mapping(address => VoteSubmission) internal submissions; // Store each voter's submission (optional retrieval)

    Winner[] public winners; // Winners computed after finalization
    bool public resultsFinalized;

    // Events
    event ApplicationSubmitted(
        uint256 indexed index,
        address indexed applicant,
        string ipfsUri
    );
    event ApplicationRemoved(uint256 indexed index, address indexed applicant);
    event VoteCast(address indexed voter, uint256[] indices, uint256[] shares);
    event ResultsFinalized(uint256 indexed timestamp);
    event PhaseUpdated(Phase newPhase);

    // Errors
    error Not_In_Phase(Phase expected);
    error Already_Registered();
    error Not_Registered();
    error Invalid_Input();
    error Already_Voted();
    error Invalid_Phase_Transition();

    /**
     * @notice Constructor to initialize the DataCommonsGovernance contract
     * @param _applicationStart Timestamp when the application phase starts
     * @param _applicationEnd Timestamp when the application phase ends
     * @param _votingEnd Timestamp when the voting phase ends
     * @param _maxWinners Maximum number of winners to select
     * @param _maxApplications Maximum number of applications allowed (0 for unlimited)
     */
    constructor(
        uint256 _applicationStart,
        uint256 _applicationEnd,
        uint256 _votingEnd,
        uint256 _maxWinners,
        uint256 _maxApplications,
        address _paymentSplitterAddress
    ) Ownable(msg.sender) {
        require(_applicationStart < _applicationEnd, "start < end");
        require(_applicationEnd < _votingEnd, "app end < vote end");
        require(_maxWinners > 0, "K>0");

        applicationStart = _applicationStart;
        applicationEnd = _applicationEnd;
        votingEnd = _votingEnd;
        maxWinners = _maxWinners;
        maxApplications = _maxApplications;
        paymentSplitterAddress = _paymentSplitterAddress;

        phase = Phase.Idle;
    }

    /**
     * @notice Starts the application phase
     * @dev Can only be called by the contract owner before the application start time
     */
    function startApplicationPhase() external onlyOwner {
        require(block.timestamp <= applicationStart, "too late to start");
        phase = Phase.Application;
        emit PhaseUpdated(phase);
    }

    /**
     * @notice Starts the voting phase
     * @dev Can only be called by the contract owner after the application end time
     */
    function startVotingPhase() external onlyOwner {
        // allow starting voting only after application end time
        require(block.timestamp >= applicationEnd, "application not ended");
        phase = Phase.Voting;
        emit PhaseUpdated(phase);
    }

    /**
     * @notice Updates the application and voting periods
     * @dev Can only be called by the contract owner
     * @param _applicationStart New timestamp for application start
     * @param _applicationEnd New timestamp for application end
     * @param _votingEnd New timestamp for voting end
     */
    function updateApplicationPeriod(
        uint256 _applicationStart,
        uint256 _applicationEnd,
        uint256 _votingEnd
    ) external onlyOwner {
        require(
            _applicationStart < _applicationEnd && _applicationEnd < _votingEnd,
            "bad times"
        );
        applicationStart = _applicationStart;
        applicationEnd = _applicationEnd;
        votingEnd = _votingEnd;
    }

    /**
     * @notice Sets the maximum number of winners
     * @dev Can only be called by the contract owner
     * @param _maxWinners New maximum number of winners
     */
    function setMaxWinners(uint256 _maxWinners) external onlyOwner {
        require(_maxWinners > 0, "K>0");
        maxWinners = _maxWinners;
    }

    /**
     * @notice Modifier to restrict functions to the application phase
     */
    modifier onlyDuringApplication() {
        if (phase != Phase.Application) revert Not_In_Phase(Phase.Application);
        _;
    }

    /**
     * @notice Submit an application during the application phase
     * @param _index Numeric index chosen by the applicant
     * @param _ipfsUri IPFS URI containing detailed application data
     */
    function submitApplication(
        uint256 _index,
        string calldata _ipfsUri
    ) external onlyDuringApplication {
        if (isApplicantRegistered[msg.sender]) revert Already_Registered();
        if (bytes(_ipfsUri).length == 0) revert Invalid_Input();
        if (maxApplications > 0 && applicationCount >= maxApplications)
            revert Invalid_Input();
        if (applications[_index].exists) revert Invalid_Input();

        Application memory a = Application({
            applicant: msg.sender,
            index: _index,
            ipfsUri: _ipfsUri,
            exists: true
        });

        applications[_index] = a;
        isApplicantRegistered[msg.sender] = true;
        applicationCount++;

        emit ApplicationSubmitted(_index, msg.sender, _ipfsUri);
    }

    /**
     * @notice Remove an application during the application phase
     * @param _index Numeric index of the application to remove
     */
    function removeApplication(uint256 _index) external onlyDuringApplication {
        Application storage a = applications[_index];
        if (!a.exists) revert Not_Registered();
        if (a.applicant != msg.sender && owner() != msg.sender)
            revert Invalid_Input();

        delete applications[_index];
        isApplicantRegistered[a.applicant] = false;
        applicationCount--;
        emit ApplicationRemoved(_index, a.applicant);
    }

    /**
     * @notice Modifier to restrict functions to the voting phase
     */
    modifier onlyDuringVoting() {
        if (phase != Phase.Voting) revert Not_In_Phase(Phase.Voting);
        _;
    }

    /**
     * @notice Cast votes during the voting phase
     * @param _indices Array of applicant indices being voted for
     * @param _shares Array of shares in basis points assigned to each index
     */
    function castVote(
        uint256[] calldata _indices,
        uint256[] calldata _shares
    ) external onlyDuringVoting nonReentrant {
        if (_indices.length == 0 || _indices.length != _shares.length)
            revert Invalid_Input();
        if (hasVoted[msg.sender]) revert Already_Voted();

        // validate indices
        for (uint256 i = 0; i < _indices.length; ++i) {
            uint256 idx = _indices[i];
            if (!applications[idx].exists) revert Invalid_Input();
            // accumulate raw score for each index
            aggregatedScores[idx] += _shares[i];
        }

        submissions[msg.sender] = VoteSubmission({
            indices: _indices,
            shares: _shares
        });
        hasVoted[msg.sender] = true;

        emit VoteCast(msg.sender, _indices, _shares);
    }

    /**
     * @notice Finalizes the results after the voting phase
     * @dev Can only be called after the voting end time
     */
    function finalizeResults() external nonReentrant {
        if (phase != Phase.Voting) revert Not_In_Phase(Phase.Voting);
        require(block.timestamp >= votingEnd, "voting still ongoing");
        require(!resultsFinalized, "already finalized");

        // collect applicants list into array
        uint256 totalApps = 0;
        // first pass: determine how many valid application entries exist
        // We'll iterate over application indices by keeping a dynamic array of seen indices. Since applicants may choose arbitrary indices,
        // we must scan mappings; to keep on-chain iteration feasible, we assume that front-end enforces a reasonable index space or registers indices sequentially.
        // For a simple implementation, we'll collect indices by scanning up to a max range derived from applicationCount.

        // To avoid expensive unbounded loops, we'll require that applications use sequential indices starting from 1..N
        // (front-end or factory should enforce). We'll attempt to read 1..(applicationCountMaxIndex)

        // Build a vector of candidate indices
        uint256[] memory candidateIndices = new uint256[](applicationCount);
        uint256 ptr = 0;
        // naive scan: look for indices starting from 1 upward until we collect applicationCount entries
        uint256 scanIdx = 1;
        while (ptr < applicationCount) {
            if (applications[scanIdx].exists) {
                candidateIndices[ptr] = scanIdx;
                ptr++;
            }
            scanIdx++;
            // safety: if scanIdx grows very large, break (shouldn't happen if front-end enforces indices)
            require(
                scanIdx <= applicationCount + 10000,
                "index space too sparse"
            );
        }

        // Now we have candidateIndices[0..applicationCount-1]
        // Sort candidates by aggregatedScores descending and pick top K
        // Implement simple selection sort for top K (gas expensive for huge counts but acceptable for small application pools)

        uint256 K = maxWinners;
        if (K > applicationCount) K = applicationCount;

        // arrays to hold top indices and their scores
        uint256[] memory topIndices = new uint256[](K);
        uint256[] memory topScores = new uint256[](K);

        for (uint256 i = 0; i < applicationCount; ++i) {
            uint256 idx = candidateIndices[i];
            uint256 score = aggregatedScores[idx];

            // try to place this candidate in top K
            for (uint256 j = 0; j < K; ++j) {
                if (score == 0 && topScores[j] == 0) {
                    // both zero, skip placement but allow later
                    break;
                }
                if (score > topScores[j]) {
                    // shift down
                    for (uint256 s = K - 1; s > j; --s) {
                        topScores[s] = topScores[s - 1];
                        topIndices[s] = topIndices[s - 1];
                    }
                    // insert
                    topScores[j] = score;
                    topIndices[j] = idx;
                    break;
                }
                // handle if topScores[j]==0 and we've reached end
                if (j == K - 1 && topScores[j] == 0) {
                    topScores[j] = score;
                    topIndices[j] = idx;
                }
            }
        }

        // compute total score among selected winners
        uint256 totalWinnerScore = 0;
        for (uint256 i = 0; i < K; ++i) {
            totalWinnerScore += topScores[i];
        }

        // Edge case: if totalWinnerScore == 0 (no votes cast or all zero), we pick first K applicants by index and assign equal shares
        winners = new Winner[](K);
        if (totalWinnerScore == 0) {
            uint256 equalShare = BASIS_POINTS / K; // integer division
            for (uint256 i = 0; i < K; ++i) {
                uint256 idx = candidateIndices[i];
                winners[i] = Winner({
                    index: idx,
                    applicant: applications[idx].applicant,
                    normalizedShare: equalShare,
                    rawScore: 0
                });
            }
            // adjust rounding for last winner
            uint256 remainder = BASIS_POINTS - (equalShare * K);
            if (remainder > 0) {
                winners[0].normalizedShare += remainder;
            }
        } else {
            // normalize shares proportionally to raw score
            uint256 accumulatedBP = 0;
            for (uint256 i = 0; i < K; ++i) {
                uint256 idx = topIndices[i];
                uint256 raw = topScores[i];
                uint256 bp = (raw * BASIS_POINTS) / totalWinnerScore; // truncated
                winners[i] = Winner({
                    index: idx,
                    applicant: applications[idx].applicant,
                    normalizedShare: bp,
                    rawScore: raw
                });
                accumulatedBP += bp;
            }
            // distribute rounding remainder to highest-ranked winner
            uint256 remainder = BASIS_POINTS - accumulatedBP;
            if (remainder > 0 && K > 0) {
                winners[0].normalizedShare += remainder;
            }
        }

        resultsFinalized = true;
        phase = Phase.Finalized;
        emit ResultsFinalized(block.timestamp);
        emit PhaseUpdated(phase);

        // logic to add the payees to the payment splitter contract
        address[] memory payees = new address[](K);
        uint256[] memory sharesBP = new uint256[](K);

        for (uint256 i = 0; i < K; ++i) {
            payees[i] = winners[i].applicant;
            sharesBP[i] = winners[i].normalizedShare;
        }

        PaymentSplitter(payable(paymentSplitterAddress)).initialize(
            payees,
            sharesBP
        );
    }

    /**
     * @notice Retrieves the vote submission of a given voter
     * @param voter Address of the voter
     * @return indices Array of applicant indices voted for
     * @return shares Array of shares in basis points assigned to each index
     */
    function getSubmission(
        address voter
    )
        external
        view
        returns (uint256[] memory indices, uint256[] memory shares)
    {
        VoteSubmission storage s = submissions[voter];
        return (s.indices, s.shares);
    }

    /**
     * @notice Retrieves the number of winners
     * @return The count of winners
     */
    function getWinnerCount() external view returns (uint256) {
        return winners.length;
    }

    /**
     * @notice Retrieves details of a specific winner by index
     * @param i Index of the winner in the winners array
     * @return index Numeric index of the winning application
     * @return applicant Address of the winning applicant
     * @return normalizedShare Normalized share in basis points
     * @return rawScore Aggregated raw score before normalization
     */
    function getWinner(
        uint256 i
    )
        external
        view
        returns (
            uint256 index,
            address applicant,
            uint256 normalizedShare,
            uint256 rawScore
        )
    {
        Winner storage w = winners[i];
        return (w.index, w.applicant, w.normalizedShare, w.rawScore);
    }

    // Fallback helpers for external tooling
    function getAggregatedScore(uint256 idx) external view returns (uint256) {
        return aggregatedScores[idx];
    }
}
