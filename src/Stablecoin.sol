// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title A sample Stablecoin
 * @author Suraj Yakkha
 * @notice You can use this contract for creating a sample Stablecoin
 * @dev Stablecoin engine governs this contract
 */
contract Stablecoin is ERC20Burnable, Ownable {
    error Stablecoin__AmountIsLessThanOne();
    error Stablecoin__BurnAmountIsMoreThanBalance();
    error Stablecoin__IsZeroAddress();

    constructor() ERC20("Stablecoin", "SC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount < 1) {
            revert Stablecoin__AmountIsLessThanOne();
        }

        if (balance < _amount) {
            revert Stablecoin__BurnAmountIsMoreThanBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) revert Stablecoin__IsZeroAddress();

        if (_amount < 1) {
            revert Stablecoin__AmountIsLessThanOne();
        }
        _mint(_to, _amount);
        return true;
    }
}
