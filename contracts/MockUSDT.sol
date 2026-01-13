// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {ERC20} from "@luxfi/standard/tokens/ERC20.sol";

/// @title Mock USDT for local testing
/// @notice Simple ERC20 with 6 decimals and public mint
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Anyone can mint for testing
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Mint 10,000 USDT to caller for testing
    function faucet() external {
        _mint(msg.sender, 10_000 * 10 ** 6);
    }
}
