// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairNAVVault} from "../src/FairNAVVault.sol";

/// Testnet deployment only.
/// Usage:
///   WETH=<testnet WETH address> forge script script/Deploy.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --account <keystore-name> --broadcast
///
/// Two independent guards:
///   1. this script refuses any chain outside the testnet allowlist before broadcasting;
///   2. the contract constructor itself reverts outside the same allowlist (rule R10),
///      so the pool cannot be deployed to a mainnet even without this script.
contract Deploy is Script {
    error NotATestnet(uint256 chainId);
    error WethHasNoCode(address weth);
    error OwnerMismatch(address expected, address actual);

    function run() external returns (FairNAVVault pool) {
        address weth = vm.envAddress("WETH");
        return deploy(weth);
    }

    function deploy(address weth) public returns (FairNAVVault pool) {
        if (!_isTestnet(block.chainid)) revert NotATestnet(block.chainid);
        if (weth.code.length == 0) revert WethHasNoCode(weth);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        pool = new FairNAVVault(IERC20(weth), deployer);
        vm.stopBroadcast();

        // post-deploy checks
        if (pool.owner() != deployer) revert OwnerMismatch(deployer, pool.owner());
        require(address(pool.asset()) == weth, "asset mismatch");
        require(!pool.paused(), "unexpectedly paused");

        console.log("FairNAVVault deployed at", address(pool));
        console.log("owner", deployer);
        console.log("chain id", block.chainid);
    }

    /// Same list as FairNAVVault.isTestnet; duplicated so the script can refuse
    /// before spending gas on a broadcast.
    function _isTestnet(uint256 chainId) internal pure returns (bool) {
        return chainId == 31337 || chainId == 11155111 || chainId == 560048 || chainId == 84532
            || chainId == 421614 || chainId == 11155420 || chainId == 80002 || chainId == 97;
    }
}
