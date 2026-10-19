// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterRaces} from "../src/HamsterRaces.sol";

contract LaunchActor {
    function deploy(address launchOwner) external returns (HamsterToken token, HamsterRaces races) {
        token = new HamsterToken();
        races = new HamsterRaces(token, launchOwner);
    }

    function move(HamsterToken token, address recipient, uint256 amount) external {
        require(token.transfer(recipient, amount));
    }
}

contract HamsterTokenTest is Test {
    HamsterToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function setUp() public {
        token = new HamsterToken();
    }

    function test_MetadataAndEntireSupply() public view {
        assertEq(token.name(), "HAMSTER");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_ConstructorEmitsSingleMint() public {
        vm.recordLogs();
        HamsterToken deployed = new HamsterToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_FactoryGetsSupplyAndApplicationsNeverTakeIt() public {
        LaunchActor factory = new LaunchActor();
        (HamsterToken launched, HamsterRaces races) = factory.deploy(alice);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(address(races)), 0);
        assertEq(launched.balanceOf(alice), 0);
        assertEq(races.owner(), alice);
        assertEq(races.resultReporter(), address(0));

        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("pool manager");
        factory.move(launched, distributor, SUPPLY / 10);
        factory.move(launched, poolManager, SUPPLY / 2);
        factory.move(launched, alice, SUPPLY * 4 / 10);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(alice), SUPPLY * 4 / 10);
        vm.prank(distributor);
        assertTrue(launched.transfer(bob, SUPPLY / 10));
        assertEq(launched.balanceOf(bob), SUPPLY / 10);
        vm.prank(poolManager);
        assertTrue(launched.transfer(spender, 123 ether));
        vm.prank(spender);
        assertTrue(launched.transfer(poolManager, 123 ether));
        assertEq(launched.balanceOf(poolManager), SUPPLY / 2);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function testFuzz_TransfersConserveSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroAndSelfTransfers() public {
        assertTrue(token.transfer(alice, 0));
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_DelegatedTransferUsesOnlyAllowance(uint256 approved, uint256 spent) public {
        approved = bound(approved, 0, SUPPLY);
        spent = bound(spent, 0, approved);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, approved);
        assertTrue(token.approve(spender, approved));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, spent));
        assertEq(token.allowance(address(this), spender), approved - spent);
        assertEq(token.balanceOf(bob), spent);
        assertEq(token.balanceOf(address(this)), SUPPLY - spent);
    }

    function test_AllowanceCanBeReplacedRevokedAndInfinite() public {
        token.approve(spender, 10 ether);
        token.approve(spender, 3 ether);
        assertEq(token.allowance(address(this), spender), 3 ether);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), bob, 1);

        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), bob, SUPPLY);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(bob), SUPPLY);
    }

    function test_InsufficientBalanceRevertsAndPreservesAllowance() public {
        vm.prank(alice);
        token.approve(spender, 2);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 2));
        token.transferFrom(alice, bob, 2);
        assertEq(token.allowance(alice, spender), 2);
        assertEq(token.balanceOf(bob), 0);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(bob, SUPPLY + 1);
    }

    function test_TransferWithoutApprovalAndOverspendRevert() public {
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), bob, 1);
        token.approve(spender, 3);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 3, 4));
        token.transferFrom(address(this), bob, 4);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), spender), 3);
    }

    function test_ZeroAddressOperationsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
        token.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), spender), 1);
    }

    function test_NoPrivilegedMintFreezeSeizeOrUpgrade() public {
        token.transfer(alice, 100 ether);
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[2] = abi.encodeWithSignature("initialize(address)", bob);
        calls[3] = abi.encodeWithSignature("pause()");
        calls[4] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[5] = abi.encodeWithSignature("freeze(address)", alice);
        calls[6] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1);
        calls[7] = abi.encodeWithSignature("seize(address)", alice);
        calls[8] = abi.encodeWithSignature("upgradeTo(address)", bob);
        calls[9] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[10] = abi.encodeWithSignature("setMinter(address)", bob);
        calls[11] = abi.encodeWithSignature("burn(uint256)", 1);
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(token).call(calls[i]);
            assertFalse(success);
            vm.prank(bob);
            (success,) = address(token).call(calls[i]);
            assertFalse(success);
        }
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_DeploymentRuntimeContainsNoForbiddenOpcode() public view {
        bytes memory runtime = address(token).code;
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            }
        }
    }

    function test_RejectsNativeCurrency() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
    }
}
