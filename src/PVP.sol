// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title Pepe Values Pepe
/// @notice Fixed-issuance ERC-20. The zero-argument constructor mints exactly 10^27 minor units
/// (1,000,000,000 PVP at 18 decimals) to `msg.sender` — the launch factory — and nothing else, ever.
/// @dev No owner, no mint path, no pause, no proxy. Supply can only fall, through `burn`/`burnFrom`,
/// which is what the fee router's buy-and-burn beneficiaries rely on.
contract PVP is ERC20Burnable {
    /// @notice 1,000,000,000 PVP in minor units. Never 10^24.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20("Pepe Values Pepe", "PVP") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
