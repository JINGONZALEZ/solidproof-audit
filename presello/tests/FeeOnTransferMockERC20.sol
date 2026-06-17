// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title FeeOnTransferMockERC20
 * @notice ERC20 that charges a percentage fee on every transfer.
 *         Used to test that the vault correctly accounts for fee-on-transfer tokens.
 *         Fee is burned (subtracted from the transferred amount).
 */
contract FeeOnTransferMockERC20 is ERC20 {
    uint8 private _decimals;
    uint256 public feePercent; // e.g. 2 = 2%

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 _feePercent
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        require(_feePercent > 0 && _feePercent < 100, "Invalid fee");
        feePercent = _feePercent;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feePercent) / 100;
        uint256 netAmount = amount - fee;
        // Burn the fee
        _burn(msg.sender, fee);
        // Transfer the net amount
        return super.transfer(to, netAmount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feePercent) / 100;
        uint256 netAmount = amount - fee;
        // Burn the fee from sender
        _burn(from, fee);
        // Reduce allowance by full amount (caller approved the full amount)
        _spendAllowance(from, msg.sender, amount);
        // Transfer the net amount
        _transfer(from, to, netAmount);
        return true;
    }
}
