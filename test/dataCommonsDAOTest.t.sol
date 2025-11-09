// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DataCommonsDAO} from "../src/dataCommonsDAO.sol";

contract DataCommonsDAOTest is Test {
    DataCommonsDAO public dao;

    address public owner;
    address public applicant1;
    address public applicant2;
    address public applicant3;
    address public voter1;
    address public voter2;

    uint256 public applicationStart;
    uint256 public applicationEnd;
    uint256 public votingEnd;

    function setUp() public {
        owner = address(this);
        applicant1 = makeAddr("applicant1");
        applicant2 = makeAddr("applicant2");
        applicant3 = makeAddr("applicant3");
        voter1 = makeAddr("voter1");
        voter2 = makeAddr("voter2");

        applicationStart = block.timestamp + 1 days;
        applicationEnd = block.timestamp + 8 days;
        votingEnd = block.timestamp + 15 days;

        dao = new DataCommonsDAO(
            applicationStart,
            applicationEnd,
            votingEnd,
            2, // maxWinners
            10, // maxApplications
            address(0) // paymentSplitterAddress
        );
    }

    function test_Constructor() public view {
        assertEq(dao.applicationStart(), applicationStart);
        assertEq(dao.applicationEnd(), applicationEnd);
        assertEq(dao.votingEnd(), votingEnd);
        assertEq(dao.maxWinners(), 2);
        assertEq(uint(dao.phase()), uint(DataCommonsDAO.Phase.Idle));
    }

    function test_StartApplicationPhase() public {
        dao.startApplicationPhase();
        assertEq(uint(dao.phase()), uint(DataCommonsDAO.Phase.Application));
    }

    function test_SubmitApplication() public {
        dao.startApplicationPhase();

        vm.prank(applicant1);
        dao.submitApplication(1, "ipfs://test1");

        (
            address applicant,
            uint256 index,
            string memory ipfsUri,
            bool exists
        ) = dao.applications(1);
        assertEq(applicant, applicant1);
        assertEq(index, 1);
        assertEq(ipfsUri, "ipfs://test1");
        assertTrue(exists);
        assertEq(dao.applicationCount(), 1);
    }

    function test_SubmitApplication_RevertIfAlreadyRegistered() public {
        dao.startApplicationPhase();

        vm.prank(applicant1);
        dao.submitApplication(1, "ipfs://test1");

        vm.prank(applicant1);
        vm.expectRevert(DataCommonsDAO.Already_Registered.selector);
        dao.submitApplication(2, "ipfs://test2");
    }

    function test_RemoveApplication() public {
        dao.startApplicationPhase();

        vm.prank(applicant1);
        dao.submitApplication(1, "ipfs://test1");

        vm.prank(applicant1);
        dao.removeApplication(1);

        (, , , bool exists) = dao.applications(1);
        assertFalse(exists);
        assertEq(dao.applicationCount(), 0);
    }

    function test_StartVotingPhase() public {
        dao.startApplicationPhase();
        vm.warp(applicationEnd);

        dao.startVotingPhase();
        assertEq(uint(dao.phase()), uint(DataCommonsDAO.Phase.Voting));
    }

    function test_CastVote() public {
        // Setup applications
        dao.startApplicationPhase();
        vm.prank(applicant1);
        dao.submitApplication(1, "ipfs://test1");
        vm.prank(applicant2);
        dao.submitApplication(2, "ipfs://test2");

        // Start voting
        vm.warp(applicationEnd);
        dao.startVotingPhase();

        uint256[] memory indices = new uint256[](2);
        indices[0] = 1;
        indices[1] = 2;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 6000;
        shares[1] = 4000;

        vm.prank(voter1);
        dao.castVote(indices, shares);

        assertTrue(dao.hasVoted(voter1));
        assertEq(dao.getAggregatedScore(1), 6000);
        assertEq(dao.getAggregatedScore(2), 4000);
    }

    function test_CastVote_RevertIfAlreadyVoted() public {
        dao.startApplicationPhase();
        vm.prank(applicant1);
        dao.submitApplication(1, "ipfs://test1");

        vm.warp(applicationEnd);
        dao.startVotingPhase();

        uint256[] memory indices = new uint256[](1);
        indices[0] = 1;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10000;

        vm.prank(voter1);
        dao.castVote(indices, shares);

        vm.prank(voter1);
        vm.expectRevert(DataCommonsDAO.Already_Voted.selector);
        dao.castVote(indices, shares);
    }

    function test_FinalizeResults() public {
        // Setup applications
        dao.startApplicationPhase();
        vm.prank(applicant1);
        dao.submitApplication(1, "ipfs://test1");
        vm.prank(applicant2);
        dao.submitApplication(2, "ipfs://test2");
        vm.prank(applicant3);
        dao.submitApplication(3, "ipfs://test3");

        // Start voting
        vm.warp(applicationEnd);
        dao.startVotingPhase();

        // Cast votes
        uint256[] memory indices = new uint256[](3);
        indices[0] = 1;
        indices[1] = 2;
        indices[2] = 3;
        uint256[] memory shares = new uint256[](3);
        shares[0] = 6000;
        shares[1] = 3000;
        shares[2] = 1000;

        vm.prank(voter1);
        dao.castVote(indices, shares);

        // Finalize
        vm.warp(votingEnd);
        dao.finalizeResults();

        assertTrue(dao.resultsFinalized());
        assertEq(uint(dao.phase()), uint(DataCommonsDAO.Phase.Finalized));
        assertEq(dao.getWinnerCount(), 2);

        // Verify top 2 winners
        (uint256 index1, address app1, uint256 share1, uint256 score1) = dao
            .getWinner(0);
        assertEq(index1, 1);
        assertEq(app1, applicant1);
        assertEq(score1, 6000);

        (uint256 index2, address app2, uint256 share2, uint256 score2) = dao
            .getWinner(1);
        assertEq(index2, 2);
        assertEq(app2, applicant2);
        assertEq(score2, 3000);

        // Shares should sum to BASIS_POINTS
        assertEq(share1 + share2, 10000);
    }

    function test_FinalizeResults_NoVotes() public {
        dao.startApplicationPhase();
        vm.prank(applicant1);
        dao.submitApplication(1, "ipfs://test1");
        vm.prank(applicant2);
        dao.submitApplication(2, "ipfs://test2");

        vm.warp(applicationEnd);
        dao.startVotingPhase();

        vm.warp(votingEnd);
        dao.finalizeResults();

        assertEq(dao.getWinnerCount(), 2);

        // Equal shares when no votes
        (, , uint256 share1, ) = dao.getWinner(0);
        (, , uint256 share2, ) = dao.getWinner(1);
        assertEq(share1 + share2, 10000);
    }

    function test_FullWorkflow() public {
        // Start application phase
        dao.startApplicationPhase();

        // Submit applications
        vm.prank(applicant1);
        dao.submitApplication(1, "ipfs://test1");
        vm.prank(applicant2);
        dao.submitApplication(2, "ipfs://test2");

        // Start voting
        vm.warp(applicationEnd);
        dao.startVotingPhase();

        // Cast votes
        uint256[] memory indices = new uint256[](2);
        indices[0] = 1;
        indices[1] = 2;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 7000;
        shares[1] = 3000;

        vm.prank(voter1);
        dao.castVote(indices, shares);

        vm.prank(voter2);
        dao.castVote(indices, shares);

        // Finalize
        vm.warp(votingEnd);
        dao.finalizeResults();

        assertTrue(dao.resultsFinalized());
        assertEq(dao.getWinnerCount(), 2);
    }
}
