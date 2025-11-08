// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../lib/forge-std/src/Test.sol";
import "../src/dataCommonsDAO.sol";

contract MockERC20 is IERC20 {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;

    mapping(address => uint256) private _balance;
    mapping(address => mapping(address => uint256)) private _allowance;
    uint256 private _totalSupply;

    function mint(address to, uint256 amount) external {
        _balance[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    // IERC20
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balance[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balance[msg.sender] >= amount, "insufficient");
        _balance[msg.sender] -= amount;
        _balance[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256) {
        return _allowance[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = _allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        require(_balance[from] >= amount, "bal");
        _allowance[from][msg.sender] = allowed - amount;
        _balance[from] -= amount;
        _balance[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract dataCommonsDAOTest is Test {
    dataCommonsDAO dao;
    MockERC20 token;

    address alice = address(0xAA);
    address bob = address(0xBB);
    address owner = address(this); // test contract deployer is owner in constructor

    uint256 constant ONE = 1e18;

    function setUp() public {
        token = new MockERC20();
        // mint tokens to users
        token.mint(alice, 1000 * ONE);
        token.mint(bob, 500 * ONE);

        // deploy DAO — constructor should set owner = msg.sender
        dao = new dataCommonsDAO(IERC20(token));
    }

    function test_deposit_and_withdraw() public {
        uint256 amount = 100 * ONE;

        // approve and deposit as alice
        vm.prank(alice);
        token.approve(address(dao), amount);

        vm.prank(alice);
        dao.depositMoney(amount);

        assertEq(dao.staked(alice), amount, "staked not updated after deposit");

        // withdraw partial
        vm.prank(alice);
        dao.withdraw(40 * ONE);

        assertEq(
            dao.staked(alice),
            60 * ONE,
            "staked not updated after withdraw"
        );

        // withdraw remaining
        vm.prank(alice);
        dao.withdraw(60 * ONE);
        assertEq(dao.staked(alice), 0, "staked should be zero");
    }

    function test_application_snapshot_and_voting_flow() public {
        uint256 t0 = block.timestamp;

        // set application window [t0+10, t0+20] and voting [t0+21, t0+60]
        uint256 appStart = t0 + 10;
        uint256 appEnd = t0 + 20;
        uint256 votingStart = t0 + 21;
        uint256 votingEnd = t0 + 60;

        // owner sets ranges (owner is this contract)
        dao.setApplicationRange(appStart, appEnd);
        dao.setVotingRange(votingStart, votingEnd);

        // warp into application window
        vm.warp(appStart + 1);

        // alice deposits 200, bob deposits 50
        vm.prank(alice);
        token.approve(address(dao), 200 * ONE);
        vm.prank(alice);
        dao.depositMoney(200 * ONE);

        vm.prank(bob);
        token.approve(address(dao), 50 * ONE);
        vm.prank(bob);
        dao.depositMoney(50 * ONE);

        // alice submits an application
        vm.prank(alice);
        dao.submitApplication("ipfs://QmAliceApp");

        // verify application stored
        dataCommonsDAO.Application memory a = dao.getApplication(1);
        assertEq(a.applicant, alice);
        assertTrue(a.exists);

        // warp to after application end and into voting start
        vm.warp(votingStart + 1);

        // calling vote before snapshot should fail (NoVotingPower)
        // We expect a revert with the custom error NoVotingPower()
        bytes4 selNoVotingPower = bytes4(keccak256("NoVotingPower()"));
        vm.expectRevert(abi.encodeWithSelector(selNoVotingPower));
        vm.prank(alice);
        dao.vote(1, true);

        // Now owner takes snapshot
        dao.startTheVotingNow();

        // After snapshot, alice and bob can vote
        vm.prank(alice);
        dao.vote(1, true);

        vm.prank(bob);
        dao.vote(1, false);

        // check weights: yesWeight == 200, noWeight == 50
        dataCommonsDAO.Application memory app = dao.getApplication(1);
        assertEq(app.yesWeight, 200 * ONE, "yes weight mismatch");
        assertEq(app.noWeight, 50 * ONE, "no weight mismatch");

        // double voting by alice should revert with AlreadyVoted()
        bytes4 selAlready = bytes4(keccak256("AlreadyVoted()"));
        vm.expectRevert(abi.encodeWithSelector(selAlready));
        vm.prank(alice);
        dao.vote(1, true);
    }

    function test_submit_outside_application_window_reverts() public {
        uint256 t0 = block.timestamp;
        dao.setApplicationRange(t0 + 100, t0 + 200);

        // we are currently before start -> should revert
        bytes4 selAppPeriod = bytes4(keccak256("ApplicationPeriodNotOver()"));
        vm.expectRevert(abi.encodeWithSelector(selAppPeriod));
        vm.prank(alice);
        dao.submitApplication("ipfs://x");
    }

    function test_set_ranges_overlap_and_invalid() public {
        uint256 t0 = block.timestamp;
        // basic invalid range: start >= end
        bytes4 selInvalid = bytes4(keccak256("InvalidTimeRange()"));
        vm.expectRevert(abi.encodeWithSelector(selInvalid));
        dao.setVotingRange(t0 + 50, t0 + 10); // start> end

        // set application first
        dao.setApplicationRange(t0 + 10, t0 + 20);

        // overlapping voting range should revert
        bytes4 selOverlap = bytes4(
            keccak256("ApplicationAndVotingTimeOverlap()")
        );
        vm.expectRevert(abi.encodeWithSelector(selOverlap));
        dao.setVotingRange(t0 + 15, t0 + 30); // starts before application end
    }

    /// @dev test that depositing zero reverts with AmountMustBeGreaterThanZero
    function test_deposit_zero_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                dataCommonsDAO.AmountMustBeGreaterThanZero.selector
            )
        );
        dao.depositMoney(0);
    }

    /// @dev test withdraw when not enough stake reverts
    function test_withdraw_insufficient_balance_reverts() public {
        vm.prank(alice);
        token.approve(address(dao), 100 * ONE);
        vm.prank(alice);
        dao.depositMoney(100 * ONE);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                dataCommonsDAO.InsufficientStakedBalance.selector
            )
        );
        dao.withdraw(200 * ONE);
    }

    /// @dev test withdraw zero amount reverts
    function test_withdraw_zero_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                dataCommonsDAO.AmountMustBeGreaterThanZero.selector
            )
        );
        dao.withdraw(0);
    }

    /// @dev test submitApplication with empty URI reverts
    function test_submit_empty_ipfs_reverts() public {
        uint256 t0 = block.timestamp;
        dao.setApplicationRange(t0, t0 + 100);

        vm.warp(t0 + 10);

        vm.expectRevert(
            abi.encodeWithSelector(dataCommonsDAO.IPFSuriCannotBeEmpty.selector)
        );
        dao.submitApplication("");
    }

    /// @dev test submit outside window (after end)
    function test_submit_after_window_reverts() public {
        uint256 t0 = block.timestamp;
        dao.setApplicationRange(t0, t0 + 10);

        vm.warp(t0 + 20);
        vm.expectRevert(
            abi.encodeWithSelector(
                dataCommonsDAO.ApplicationPeriodNotOver.selector
            )
        );
        dao.submitApplication("ipfs://abc");
    }

    /// @dev test overlapping setApplicationRange & setVotingRange combinations
    function test_application_voting_overlap_reverts() public {
        uint256 t0 = block.timestamp;
        dao.setApplicationRange(t0, t0 + 50);
        // try to set voting that overlaps
        vm.expectRevert(
            abi.encodeWithSelector(
                dataCommonsDAO.ApplicationAndVotingTimeOverlap.selector
            )
        );
        dao.setVotingRange(t0 + 40, t0 + 100);
    }

    /// @dev test snapshot can only be taken once
    function test_snapshot_can_only_be_taken_once() public {
        uint256 t0 = block.timestamp;
        dao.setApplicationRange(t0, t0 + 10);
        dao.setVotingRange(t0 + 11, t0 + 20);

        // warp to after app window
        vm.warp(t0 + 12);

        // deposit before snapshot
        vm.prank(alice);
        token.approve(address(dao), 100 * ONE);
        vm.prank(alice);
        dao.depositMoney(100 * ONE);

        // take snapshot once
        dao.startTheVotingNow();

        // second attempt should revert
        vm.expectRevert(
            abi.encodeWithSelector(dataCommonsDAO.SnapshotAlreadyTaken.selector)
        );
        dao.startTheVotingNow();
    }

    /// @dev test vote outside voting phase
    function test_vote_outside_voting_phase_reverts() public {
        uint256 t0 = block.timestamp;
        dao.setApplicationRange(t0, t0 + 10);
        dao.setVotingRange(t0 + 11, t0 + 20);

        // before voting start
        vm.warp(t0 + 5);
        vm.expectRevert(
            abi.encodeWithSelector(
                dataCommonsDAO.VotingPhaseNotGoingOn.selector
            )
        );
        dao.vote(1, true);
    }

    /// @dev test owner can set valid ranges properly and emit events
    function test_set_ranges_emit_events() public {
        uint256 t0 = block.timestamp;
        vm.expectEmit(true, false, false, true);
        emit dataCommonsDAO.ApplicationTimeSet(t0, t0 + 10);
        dao.setApplicationRange(t0, t0 + 10);

        vm.expectEmit(true, false, false, true);
        emit dataCommonsDAO.votingTimeSet(t0 + 11, t0 + 20);
        dao.setVotingRange(t0 + 11, t0 + 20);
    }

    /// @dev test getApplication for non-existent app
    function test_getApplication_nonexistent_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                dataCommonsDAO.ApplicationDoesNotExist.selector
            )
        );
        dao.getApplication(99);
    }

    /// @dev test full deposit-withdraw cycle maintains balances correctly

    /// @dev test multiple stakers snapshot accuracy
    
}
