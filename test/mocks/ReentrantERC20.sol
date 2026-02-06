// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ReentrantERC20 is ERC20 {
    uint8 private immutable tokenDecimals;
    address public target;
    bytes public data;
    bool public armed;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok,) = target.call(data);
            require(ok, "reenter failed");
        }
        return super.transferFrom(from, to, amount);
    }
}
