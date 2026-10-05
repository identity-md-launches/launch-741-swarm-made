// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Swarm Made (MADE)
/// @notice A plain, fixed-supply community token.
/// @dev Design, in one place:
///      - The whole supply (1,000,000,000 MADE, 18 decimals) is minted once, in the constructor, to
///        `msg.sender`. In the IdentityMD launch flow that sender is the ProjectFactory, which then
///        forwards the swarm share, seeds the pool and sends the remainder on.
///      - There is no owner, no minter, no pause, no blocklist, no fee, no burn hook and no upgrade
///        path. Nothing in this contract can grow the supply or move a holder's balance without
///        that holder's authorisation (a direct transfer or an ERC-20 allowance).
///      - The constructor takes no arguments, so there are no launch addresses to exempt: every
///        transfer, including the factory's, the distributor's and the PoolManager's, moves exactly
///        the amount requested.
///      - Behaviour is OpenZeppelin v5 `ERC20` unmodified: transfers to or from the zero address
///        revert, as does any transfer or allowance spend that exceeds the available balance or
///        allowance. Transfers to self are allowed. Zero-value transfers are allowed.
contract SwarmMade is ERC20 {
    /// @notice Human-readable name, fixed at deployment.
    string public constant TOKEN_NAME = "Swarm Made";
    /// @notice Ticker, fixed at deployment.
    string public constant TOKEN_SYMBOL = "MADE";
    /// @notice Total supply in minor units (1,000,000,000 * 10^18). Never changes after the constructor.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints the entire fixed supply to the deployer.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
