// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SwarmMade} from "../src/SwarmMade.sol";

/// @title Deploy script and launch parameters for Swarm Made (MADE)
/// @notice The production path is ProjectFactory.launchCustom, driven by the network's deployer from
///         the launch manifest. This script exists so the parameters live in reviewable code, so the
///         deployment can be rehearsed on a local or test chain, and so tests can exercise the exact
///         function the deployment calls. It never reads environment variables and never holds keys.
contract DeploySwarmMade is Script {
    /// @notice Everything the launch needs to know about this token, as fixed constants.
    struct LaunchConfig {
        /// @dev Share of the whole supply that seeds the single-sided pool, in basis points.
        uint16 poolBps;
        /// @dev Opening market cap, in minor units of the paired currency (IMD, 18 decimals).
        uint256 initialMarketCapWei;
        /// @dev Receives the rest of the requester's share after the swarm share and the pool seed.
        address remainderTo;
        /// @dev Expected totalSupply in minor units; the manifest must state exactly this.
        uint256 totalSupply;
        /// @dev Expected decimals; the manifest must state exactly this.
        uint8 decimals;
    }

    uint16 public constant POOL_BPS = 8_800;
    uint256 public constant INITIAL_MARKET_CAP_WEI = 2_500 ether;
    address public constant REMAINDER_TO = 0x1846927b920FA2D41766ED4F88F1d10e640F1590;

    /// @notice The configuration the manifest copies. Pure so tests and reviewers can read it anywhere.
    function launchConfig() public pure returns (LaunchConfig memory) {
        return LaunchConfig({
            poolBps: POOL_BPS,
            initialMarketCapWei: INITIAL_MARKET_CAP_WEI,
            remainderTo: REMAINDER_TO,
            totalSupply: 1_000_000_000 * 10 ** 18,
            decimals: 18
        });
    }

    /// @notice Deploys the token. The caller of this function (the broadcaster in `run`, or the
    ///         factory in production) receives the whole supply. Takes no configuration because the
    ///         token has none: name, symbol and supply are compiled in.
    function deploy() public returns (SwarmMade token) {
        token = new SwarmMade();
    }

    /// @notice Rehearsal entry point for `forge script`. Broadcasting is the operator's decision at
    ///         the command line; nothing here signs or sends on its own.
    function run() external returns (SwarmMade token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
