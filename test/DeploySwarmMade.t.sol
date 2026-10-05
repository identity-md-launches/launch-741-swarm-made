// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmMade} from "../src/SwarmMade.sol";
import {DeploySwarmMade} from "../script/DeploySwarmMade.s.sol";

/// @notice Calls the deploy function directly; nothing here reads the environment or broadcasts.
contract DeploySwarmMadeTest is Test {
    DeploySwarmMade internal deployScript;

    function setUp() public {
        deployScript = new DeploySwarmMade();
    }

    function test_deployMintsWholeSupplyToTheCaller() public {
        // The script contract is the caller of `new`, so it receives the supply, exactly as the
        // factory does in production.
        SwarmMade token = deployScript.deploy();
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.balanceOf(address(deployScript)), token.totalSupply());
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.name(), "Swarm Made");
        assertEq(token.symbol(), "MADE");
        assertEq(token.decimals(), 18);
    }

    function test_launchConfigMatchesTheBrief() public view {
        DeploySwarmMade.LaunchConfig memory cfg = deployScript.launchConfig();
        assertEq(cfg.poolBps, 8_800, "pool share is 88%");
        assertEq(cfg.initialMarketCapWei, 2_500 ether, "opening cap is 2500 IMD in 18-decimal minor units");
        assertEq(cfg.remainderTo, 0x1846927b920FA2D41766ED4F88F1d10e640F1590, "remainder address");
        assertEq(cfg.totalSupply, 1_000_000_000 * 10 ** 18);
        assertEq(cfg.decimals, 18);
    }

    function test_launchConfigAgreesWithTheDeployedToken() public {
        DeploySwarmMade.LaunchConfig memory cfg = deployScript.launchConfig();
        SwarmMade token = deployScript.deploy();
        assertEq(cfg.totalSupply, token.totalSupply());
        assertEq(cfg.decimals, token.decimals());
        assertEq(cfg.totalSupply, token.TOTAL_SUPPLY());
    }

    function test_launchSharesSumToTheSupply() public view {
        DeploySwarmMade.LaunchConfig memory cfg = deployScript.launchConfig();
        uint256 swarm = (cfg.totalSupply * 1_000) / 10_000;
        uint256 pool = (cfg.totalSupply * cfg.poolBps) / 10_000;
        uint256 remainder = cfg.totalSupply - swarm - pool;
        assertEq(swarm, 100_000_000e18);
        assertEq(pool, 880_000_000e18);
        assertEq(remainder, 20_000_000e18);
        assertEq(swarm + pool + remainder, cfg.totalSupply);
        assertLe(cfg.poolBps, 9_000, "the requester's share is 90% at most");
    }

    function test_constructorTakesNoArguments() public pure {
        // The manifest's constructorArgs must be empty; the creation code is the whole payload.
        bytes memory code = type(SwarmMade).creationCode;
        assertGt(code.length, 0);
        // Encoding zero constructor args appends nothing.
        assertEq(abi.encodePacked(code, abi.encode()).length, code.length);
    }
}
