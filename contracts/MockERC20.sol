// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {ERC20} from "@luxfi/standard/tokens/ERC20.sol";

/// @title Mock ERC20 for local testing
/// @notice Flexible mock ERC20 with configurable name, symbol, and decimals
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Anyone can mint for testing
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Mint 10,000 tokens to caller for testing
    function faucet() external {
        _mint(msg.sender, 10_000 * 10 ** _decimals);
    }

    /// @notice Burn tokens
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
