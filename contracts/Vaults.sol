// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "LoanToken.sol";

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
        uint256 interestRatePerSecond; // e18
        uint256 minCollateralRatio; // in percent
    }

    struct Vault {
        uint256 id;
        VaultScheme scheme;
        address owner;
        uint256 lastInterestUpdateTStamp;
        mapping(IERC20=>uint256) collaterals;
        mapping(LoanToken => uint256) loans;
    }

    address private owner;

    uint256 internal nextVaultId;
    mapping(uint256 => Vault) public vaults;

    IERC20[] public allowedCollaterals;
    LoanToken[] public allowedLoans;
    VaultScheme[] public possibleSchemes;

    mapping(address => uint256) public oraclePrices;
    mapping(address => bool) private allowedOracles;

    constructor() {
        owner= msg.sender;
        nextVaultId = 1;
        possibleSchemes.push(VaultScheme(1585489599,150)); //5% APR
    }

    function allowOracle(address newOracle) external {
        require(msg.sender == owner,"Only owner can add possible collateral");
        allowedOracles[newOracle]= true;
    }

    function denyOracle(address newOracle) external {
        require(msg.sender == owner,"Only owner can add possible collateral");
        allowedOracles[newOracle]= false;
    }

    struct OraclePrice {
        address tokenAddress;
        uint256 price;
    }

    //encode parameter like this: [["0xaddressOfToken",1234],["0xaddressOfNextToken",5678]]
    function setOraclePrices(OraclePrice[] calldata prices) external {
        for (uint256 i = 0; i < prices.length; i++) {
            OraclePrice calldata price= prices[i];
            oraclePrices[price.tokenAddress]= price.price;
        }
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
        vault.lastInterestUpdateTStamp= block.timestamp;
        return vaultId;
    }

    function addPossibleCollateral(IERC20 token) external {
        require(msg.sender == owner,"Only owner can add possible collateral");
        allowedCollaterals.push(token);
    }

    function createLoanToken(string memory _name, string memory _symbol) external {
        require(msg.sender == owner,"Only owner can add loanToken");
        LoanToken newToken= new LoanToken(_name,_symbol,address(this));
        allowedLoans.push(newToken);
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

    
    function paybackLoan(uint256 vaultId,LoanToken token, uint256 amount) external payable {
        //token and amount in msg.data
        Vault storage vault= getVault(vaultId); //no need to check for owner. anyone can payback loans
        uint256 openLoan= vault.loans[token];
        updateInterest(vaultId);
        require(openLoan > 0,"can't payback empty loan");
        if(openLoan < amount) {
            amount = openLoan;
        }
        token.burn(msg.sender,amount);
        vault.loans[token] -= amount;
    }

    function takeLoan(uint256 vaultId,LoanToken token, uint256 amount) external {
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
        updateInterest(vaultId);
        uint newRatio= getCollRatioForVaultWithDelta(vaultId, address(0x0), 0, address(token), amount);
        require(newRatio >= vault.scheme.minCollateralRatio, "minCollRatio must be met");
        token.mint(msg.sender,amount);
        vault.loans[token] += amount;
    }

    function removeCollateral(uint256 vaultId, IERC20 token,uint256 amount) external {
        Vault storage vault= getOwnedVault(vaultId);
         uint256 coll= vault.collaterals[token];
        updateInterest(vaultId);
        uint newRatio= getCollRatioForVaultWithDelta(vaultId, address(token), amount, address(0x0), 0);
        require(newRatio >= vault.scheme.minCollateralRatio, "minCollRatio must be met");
        require(coll > 0,"can't withdraw if not there");
        if(coll < amount) {
            amount = coll;
        }
        token.transfer(msg.sender,amount);
        vault.collaterals[token] -= amount;
    }

    //======================== liquidations

    function liquidateVault(uint256 vaultId) external {
        Vault storage vault= getVault(vaultId);
        uint ratio= getCollRatioForVault(vaultId);
        require(ratio < vault.scheme.minCollateralRatio,"Can only liquidate if ratio below min");
        updateInterest(vaultId);

        for (uint256 i = 0; i < allowedLoans.length; i++) {
            LoanToken token = allowedLoans[i];
            if(vault.loans[token] > 0) {
                //sender needs to payback loan 
                token.burn(msg.sender, vault.loans[token]); //fails if msg.sender doesn't have the coins. right?!
                vault.loans[token] = 0;
            }
        }
        for (uint256 i = 0; i < allowedCollaterals.length; i++) {
            IERC20 coll= allowedCollaterals[i];
            if(vault.collaterals[coll] > 0) {
                coll.transfer(msg.sender,vault.collaterals[coll]);
                vault.collaterals[coll] = 0;
            } 
        }

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

    function updateInterest(uint256 vaultId) private {
        Vault storage vault= getVault(vaultId);
        uint256 secondsSinceUpdate = block.timestamp - vault.lastInterestUpdateTStamp;
        uint256 interestToApply= vault.scheme.interestRatePerSecond*secondsSinceUpdate;
        for (uint256 i = 0; i < allowedLoans.length; i++) {
            LoanToken token = allowedLoans[i];
            if(vault.loans[token] > 0) {
                vault.loans[token] += (vault.loans[token]*interestToApply)/(10**18);
            }
        }
        vault.lastInterestUpdateTStamp= block.timestamp;
    }

    function getCollRatioForVault(uint256 vaultId) public view returns(uint collRatio) {
        Vault storage vault= getVault(vaultId);
        uint256 totalCollValue= 0;
        uint256 totalLoanValue= 0;
        for (uint256 i = 0; i < allowedCollaterals.length; i++) {
            IERC20 coll= allowedCollaterals[i];
            uint256 oracle= oraclePrices[address(coll)];
            totalCollValue += (vault.collaterals[coll]*oracle); 
        }
        for (uint256 i = 0; i < allowedLoans.length; i++) {
            LoanToken token = allowedLoans[i];
            uint256 oracle= oraclePrices[address(token)];
            totalLoanValue += (vault.loans[token]*oracle);
        }
        return totalLoanValue/totalCollValue;
    }
    
    function getCollRatioForVaultWithDelta(uint256 vaultId,address collToken, uint256 removedColl, address loanToken, uint256 addLoan) internal view returns(uint collRatio) {
        Vault storage vault= getVault(vaultId);
        uint256 totalCollValue= 0;
        uint256 totalLoanValue= 0;
        for (uint256 i = 0; i < allowedCollaterals.length; i++) {
            IERC20 coll= allowedCollaterals[i];
            uint256 oracle= oraclePrices[address(coll)];
            uint256 usedAmount= vault.collaterals[coll];
            if(collToken == address(coll)) {
                if(usedAmount < removedColl) {
                    usedAmount = 0;
                } else {
                    usedAmount -= removedColl;
                }
            }
            totalCollValue += (usedAmount*oracle); 
        }
        for (uint256 i = 0; i < allowedLoans.length; i++) {
            LoanToken token = allowedLoans[i];
            uint256 oracle= oraclePrices[address(token)];
            uint256 usedAmount= vault.loans[token];
            if(loanToken == address(token)) {
                usedAmount += addLoan;
            }
            totalLoanValue += (usedAmount*oracle);
        }
        return totalLoanValue/totalCollValue;
    }
}
