// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairNAVVault} from "../src/FairNAVVault.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// From an AI-assisted code review: "testnet only" must be enforced, not just claimed.
contract DeployTest is Test {
    MockWETH weth;
    Deploy script;

    function setUp() public {
        weth = new MockWETH();
        script = new Deploy();
    }

    function test_ScriptDeploysOnSepoliaAndSetsOwner() public {
        vm.chainId(11155111);
        FairNAVVault pool = script.deploy(address(weth));
        assertEq(address(pool.asset()), address(weth));
        assertTrue(pool.owner() != address(0));
    }

    function test_ScriptRefusesEveryMainnet() public {
        uint256[6] memory mainnets = [uint256(1), 56, 137, 8453, 42161, 10]; // ETH, BNB, Polygon, Base, Arbitrum, OP
        for (uint256 i; i < mainnets.length; i++) {
            vm.chainId(mainnets[i]);
            vm.expectRevert(abi.encodeWithSelector(Deploy.NotATestnet.selector, mainnets[i]));
            script.deploy(address(weth));
        }
    }

    function test_ScriptRefusesWethWithoutCode() public {
        vm.chainId(11155111);
        address notAContract = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Deploy.WethHasNoCode.selector, notAContract));
        script.deploy(notAContract);
    }

    /// The contract enforces R10 on its own, so even a direct deployment that skips
    /// the script cannot land on a mainnet.
    function test_ContractItselfRefusesMainnet() public {
        uint256[6] memory mainnets = [uint256(1), 56, 137, 8453, 42161, 10];
        for (uint256 i; i < mainnets.length; i++) {
            vm.chainId(mainnets[i]);
            vm.expectRevert(abi.encodeWithSelector(FairNAVVault.NotATestnet.selector, mainnets[i]));
            new FairNAVVault(IERC20(address(weth)), address(this));
        }
    }

    function testFuzz_ContractOnlyDeploysOnAllowlist(uint64 chainId) public {
        vm.assume(chainId != 0);
        vm.chainId(chainId);
        FairNAVVault probe;
        bool allowed = chainId == 31337 || chainId == 11155111 || chainId == 560048 || chainId == 84532
            || chainId == 421614 || chainId == 11155420 || chainId == 80002 || chainId == 97;
        if (allowed) {
            probe = new FairNAVVault(IERC20(address(weth)), address(this));
            assertEq(probe.owner(), address(this));
        } else {
            vm.expectRevert(abi.encodeWithSelector(FairNAVVault.NotATestnet.selector, uint256(chainId)));
            new FairNAVVault(IERC20(address(weth)), address(this));
        }
    }
}
