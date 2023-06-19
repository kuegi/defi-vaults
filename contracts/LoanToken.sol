// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract LoanToken is ERC20 {
    address minter;

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        minter = msg.sender;
    }

    function mint(address _to, uint256 _amount) external {
        require(msg.sender == minter, 'Only minter can mint');
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external {
        require(msg.sender == minter, 'Only minter can burn');
        _burn(_from, _amount);
    }
}
