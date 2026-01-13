// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {IERC20} from "@luxfi/standard/tokens/ERC20.sol";

/**
 * @title IPARS
 * @notice Interface for the PARS emissions token
 */
interface IPARS is IERC20 {
    /// @notice Mint PARS tokens (restricted to minter role)
    function mint(address to, uint256 amount) external;

    /// @notice Burn PARS tokens
    function burn(uint256 amount) external;

    /// @notice Set new minter address
    function setMinter(address newMinter) external;

    /// @notice Get current minter address
    function minter() external view returns (address);
}
