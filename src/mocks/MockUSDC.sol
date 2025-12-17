// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC token for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // Public for testing
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Public for testing
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

