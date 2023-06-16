// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "ILoanToken.sol";

/**
interest of a vault is calculated and applied if anything is done to the vault (add/remove collateral, take/payback loan)
 */

error InvalidCollateral();
error InvalidLoan();
error VaultNotFound();
error VaultClosed();
error NotOwner();
error InvalidScheme();

contract Vaults {
    struct VaultScheme {
        uint256 interestRate; // in 1/10 percent
        uint256 minCollateralRatio; // in percent
    }

    struct Vault {
        uint256 id;
        VaultScheme scheme;
        address owner;
        uint256 lastChangeBlock;
        mapping(IERC20=>uint256) collaterals;
        mapping(ILoanToken => uint256) loans;
    }

    address private owner;

    uint256 internal nextVaultId;
    mapping(uint256 => Vault) public vaults;

    IERC20[] public allowedCollaterals;
    ILoanToken[] public allowedLoans;
    VaultScheme[] possibleSchemes;

    mapping(IERC20 => uint256) public oraclePrices;

    constructor() {
        owner= msg.sender;
        nextVaultId = 1;
    }

    function createVault(uint256 scheme) external returns(uint256 id) {
        if(scheme >= possibleSchemes.length) {
            revert InvalidScheme();
        }
        uint256 vaultId= nextVaultId++;
        Vault storage vault= vaults[vaultId];
        vault.id= vaultId;
        vault.scheme= possibleSchemes[scheme];
        vault.owner= msg.sender;
        return vaultId;
    }

    function addCollateral(uint256 vaultId,IERC20 token, uint256 _amount) external payable {
        //token and amount in msg.data
        Vault storage vault= getVault(vaultId); //no need to check for owner. anyone can add collateral
        
        bool foundIt= false;
        for (uint256 i = 0; i < allowedCollaterals.length; i++) {
            if(allowedCollaterals[i] == token) {
                foundIt = true;
                break;
            }
        }
        if(!foundIt) {
            revert InvalidCollateral(); 
        }
        token.transferFrom(msg.sender,address(this),_amount);
        vault.collaterals[token] += _amount;
    }

    
    function paybackLoan(uint256 vaultId,ILoanToken token, uint256 amount) external payable {
        //token and amount in msg.data
        Vault storage vault= getVault(vaultId); //no need to check for owner. anyone can payback loans
        uint256 openLoan= vault.loans[token];
        //TODO: apply interest
        require(openLoan > 0,"can't payback empty loan");
        if(openLoan < amount) {
            amount = openLoan;
        }
        token.burn(msg.sender,amount);
        vault.loans[token] -= amount;
    }

    function takeLoan(uint256 vaultId,ILoanToken token, uint256 amount) external {
        Vault storage vault= getOwnedVault(vaultId);
        bool foundIt= false;
        for (uint256 i = 0; i < allowedLoans.length; i++) {
            if(allowedLoans[i] == token) {
                foundIt = true;
                break;
            }
        }
        if(!foundIt) {
            revert InvalidLoan(); 
        }
        //apply interest to loans
        //TODO: check collateral ratio
        token.mint(msg.sender,amount);
        vault.loans[token] += amount;
    }

    function removeCollateral(uint256 vaultId, IERC20 token,uint256 amount) external {
        Vault storage vault= getOwnedVault(vaultId);
         uint256 coll= vault.collaterals[token];
        //TODO: apply interest
        //TODO: check coll ratio 
        require(coll > 0,"can't withdraw if not there");
        if(coll < amount) {
            amount = coll;
        }
        token.transfer(msg.sender,amount);
        vault.collaterals[token] -= amount;
    }


    // internals

    function getVault(uint256 vaultId) internal view returns(Vault storage v) {  
        if(vaultId >= nextVaultId) {
            revert VaultNotFound();
        }      
        Vault storage vault= vaults[vaultId];
        if(vault.id != vaultId) {
            revert VaultClosed();
        }
        return vault;
    }

    function getOwnedVault(uint256 vaultId) internal view returns(Vault storage v){              
        Vault storage vault= getVault(vaultId);
        if(vault.owner != msg.sender) {
            revert NotOwner();
        }
        return vault;
    }
}
