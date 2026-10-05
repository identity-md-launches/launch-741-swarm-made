// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmMade} from "../src/SwarmMade.sol";
import {DeploySwarmMade} from "../script/DeploySwarmMade.s.sol";

/// @notice The launch parameters checked against what the launch will do with them, and the script
///         exercised through the entry point the rehearsal uses. Nothing here reads the environment,
///         signs or sends: `run` inside a test only redirects the deployer, it broadcasts nothing.
contract DeploySwarmMadeAdversarialTest is Test {
    /// @dev Uniswap v4's accepted sqrtPriceX96 range: TickMath.MIN_SQRT_PRICE and MAX_SQRT_PRICE.
    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 internal constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    DeploySwarmMade internal deployScript;

    function setUp() public {
        deployScript = new DeploySwarmMade();
    }

    function test_launchConfigAgreesWithThePublicConstants() public view {
        DeploySwarmMade.LaunchConfig memory cfg = deployScript.launchConfig();
        assertEq(cfg.poolBps, deployScript.POOL_BPS());
        assertEq(cfg.initialMarketCapWei, deployScript.INITIAL_MARKET_CAP_WEI());
        assertEq(cfg.remainderTo, deployScript.REMAINDER_TO());
        assertEq(cfg.totalSupply, 1_000_000_000e18);
        assertEq(cfg.initialMarketCapWei, 2_500e18);
    }

    function test_remainderAddressIsUsable() public {
        address to = deployScript.REMAINDER_TO();
        assertTrue(to != address(0), "remainder would be burned");
        assertTrue(uint160(to) > 0xff, "remainder would go to a precompile");
        assertTrue(to != address(deployScript));
        SwarmMade token = deployScript.deploy();
        assertTrue(to != address(token), "remainder would be stuck in the token");
        // A transfer to it, as the factory makes, lands whole.
        vm.prank(address(deployScript));
        assertTrue(token.transfer(to, 20_000_000e18));
        assertEq(token.balanceOf(to), 20_000_000e18);
    }

    /// @dev The deployer derives the opening price from the cap and the supply. That price must not
    ///      truncate to zero in minor units and must be representable as a v4 sqrtPriceX96 whichever
    ///      side of the pair the token lands on, or the seed reverts and the launch is refused.
    function test_openingPriceIsRepresentableInEitherCurrencyOrder() public view {
        DeploySwarmMade.LaunchConfig memory cfg = deployScript.launchConfig();
        // IMD wei per whole MADE: 2.5e21 * 1e18 / 1e27 = 2.5e12, well above zero.
        uint256 weiPerToken = (cfg.initialMarketCapWei * 1e18) / cfg.totalSupply;
        assertEq(weiPerToken, 2_500_000_000_000, "wei of IMD per whole MADE");
        assertGt(weiPerToken, 0, "the opening price truncates to nothing");

        // Token is currency0: price = cap / supply. Token is currency1: price = supply / cap.
        uint256 tokenFirst = _sqrt((cfg.initialMarketCapWei << 192) / cfg.totalSupply);
        uint256 tokenSecond = _sqrt((cfg.totalSupply << 192) / cfg.initialMarketCapWei);
        assertGe(tokenFirst, MIN_SQRT_PRICE, "price below the v4 minimum with the token as currency0");
        assertLt(tokenFirst, MAX_SQRT_PRICE, "price above the v4 maximum with the token as currency0");
        assertGe(tokenSecond, MIN_SQRT_PRICE, "price below the v4 minimum with the token as currency1");
        assertLt(tokenSecond, MAX_SQRT_PRICE, "price above the v4 maximum with the token as currency1");
        assertLe(tokenFirst, type(uint160).max);
        assertLe(tokenSecond, type(uint160).max);
    }

    /// @dev The requester's split leaves exactly 2% after the swarm's fixed 10%, and `poolBps` fits
    ///      the manifest's type with room for nothing the brief did not ask for.
    function test_splitLeavesTheRemainderTheBriefDescribes() public view {
        DeploySwarmMade.LaunchConfig memory cfg = deployScript.launchConfig();
        uint256 swarm = (cfg.totalSupply * 1_000) / 10_000;
        uint256 pool = (cfg.totalSupply * cfg.poolBps) / 10_000;
        assertEq(cfg.totalSupply - swarm - pool, 20_000_000e18);
        assertEq((cfg.totalSupply * cfg.poolBps) % 10_000, 0, "the pool share does not divide evenly");
        assertEq(cfg.poolBps, 8_800);
        assertLe(uint256(cfg.poolBps) + 1_000, 10_000);
    }

    /// @dev Calling deploy twice does not re-mint into the first token: each call is a new, independent
    ///      token with its own supply, and nothing crosses between them.
    function test_deployTwiceGivesTwoIndependentTokens() public {
        SwarmMade first = deployScript.deploy();
        SwarmMade second = deployScript.deploy();
        assertTrue(address(first) != address(second));
        assertEq(first.totalSupply(), 1_000_000_000e18);
        assertEq(second.totalSupply(), 1_000_000_000e18);
        assertEq(first.balanceOf(address(deployScript)), 1_000_000_000e18);
        assertEq(second.balanceOf(address(deployScript)), 1_000_000_000e18);
        vm.prank(address(deployScript));
        first.transfer(address(this), 1e18);
        assertEq(second.balanceOf(address(this)), 0);
        assertEq(second.balanceOf(address(deployScript)), 1_000_000_000e18);
    }

    /// @dev The rehearsal entry point: the supply goes to the broadcaster, exactly as DEPLOYMENT.md
    ///      says, and not to the script contract. Whoever `forge script` signs as is the holder.
    function test_runMintsToTheBroadcasterNotTheScript() public {
        SwarmMade token = deployScript.run();
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(tx.origin), 1_000_000_000e18, "the broadcaster does not hold the supply");
        assertEq(token.balanceOf(address(deployScript)), 0, "the script contract kept the supply");
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_scriptHoldsNoStateAndNoConfiguration() public {
        // The script's only state is the forge `vm` handle; the parameters are constants, so two
        // instances agree without any setup.
        DeploySwarmMade other = new DeploySwarmMade();
        assertEq(keccak256(abi.encode(other.launchConfig())), keccak256(abi.encode(deployScript.launchConfig())));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
