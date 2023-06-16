// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "Vaults.sol";

contract LoanToken is ILoanToken, ERC20 {

    Vaults vaults;

    constructor(string memory _name, string memory _symbol,Vaults _vaults) ERC20(_name,_symbol) {
        vaults= _vaults;
    }

    function mint(address _to, uint256 _amount) external{
        require(msg.sender == address(vaults),"Only vaults can mint");
        _mint(_to,_amount);
    }
    

    function burn(address _from, uint256 _amount) external{
        require(msg.sender == address(vaults),"Only vaults can burn");
        _burn(_from,_amount);
    }   

}
