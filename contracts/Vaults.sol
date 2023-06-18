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
    mapping(address => uint256[]) public vaultsByOwner;

    IERC20[] public allowedCollaterals;
    LoanToken[] public allowedLoans;
    VaultScheme[] public possibleSchemes;

    mapping(address => uint256) public oraclePrices;
    address private oracle;

    constructor() {
        owner= msg.sender;
        nextVaultId = 1;
        possibleSchemes.push(VaultScheme(1585489599,150)); //5% APR
    }

    function setOracle(address newOracle) external {
        require(msg.sender == owner,"Only owner can add possible collateral");
       oracle= newOracle;
    }

    struct OraclePrice {
        address tokenAddress;
        uint256 price;
    }

    //encode parameter like this: [["0xaddressOfToken",1234],["0xaddressOfNextToken",5678]]
    function setOraclePrices(OraclePrice[] calldata prices) external {
        require(msg.sender == oracle,"Only oracle can set prices");
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
        vaultsByOwner[msg.sender].push(vault.id);
        return vaultId;
    }

    function addPossibleCollateral(IERC20 token) external {
        require(msg.sender == owner,"Only owner can add possible collateral");
        allowedCollaterals.push(token);
    }

    function createLoanToken(string memory _name, string memory _symbol) external returns(address token) {
        require(msg.sender == owner,"Only owner can add loanToken");
        LoanToken newToken= new LoanToken(_name,_symbol,address(this));
        allowedLoans.push(newToken);
        return address(newToken);
    }

    function addCollateral(uint256 vaultId,IERC20 token, uint256 _amount) external  {
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

    function removeCollateral(uint256 vaultId, IERC20 token,uint256 amount) external returns (uint256 usedAmount) {
        Vault storage vault= getOwnedVault(vaultId);
         uint256 coll= vault.collaterals[token];
        int newRatio= getCollRatioForVaultWithDelta(vaultId, address(token), amount, address(0x0), 0);
        require(newRatio < 0 || uint(newRatio) >= vault.scheme.minCollateralRatio, "minCollRatio must be met");
        require(coll > 0,"can't withdraw if not there");
        if(coll < amount) {
            amount = coll;
        }
        token.transfer(msg.sender,amount);
        vault.collaterals[token] -= amount;
        return amount;
    }
    
    function paybackLoan(uint256 vaultId,LoanToken token, uint256 amount) external returns (uint256 paid) {
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
        return amount;
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
        int newRatio= getCollRatioForVaultWithDelta(vaultId, address(0x0), 0, address(token), amount);
        require(newRatio < 0 || uint(newRatio) >= vault.scheme.minCollateralRatio, "minCollRatio must be met");
        token.mint(msg.sender,amount);
        vault.loans[token] += amount;
    }


    //======================== liquidations

    function liquidateVault(uint256 vaultId) external {
        Vault storage vault= getVault(vaultId);
        int ratio= getCollRatioForVault(vaultId);
        require(ratio > 0 && uint(ratio) < vault.scheme.minCollateralRatio,"Can only liquidate if ratio below min");
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
        uint256 interestToApply= vault.scheme.interestRatePerSecond*(block.timestamp - vault.lastInterestUpdateTStamp);
        for (uint256 i = 0; i < allowedLoans.length; i++) {
            LoanToken token = allowedLoans[i];
            if(vault.loans[token] > 0) {
                vault.loans[token] += (vault.loans[token]*interestToApply)/(10**18);
            }
        }
        vault.lastInterestUpdateTStamp= block.timestamp;
    }

    function getCollRatioForVault(uint256 vaultId) public view returns(int collRatio) {
        Vault storage vault= getVault(vaultId);
        uint256 totalCollValue= 0;
        uint256 totalLoanValue= 0;
        uint256 interestToApply= vault.scheme.interestRatePerSecond*(block.timestamp - vault.lastInterestUpdateTStamp);
        for (uint256 i = 0; i < allowedCollaterals.length; i++) {
            IERC20 coll= allowedCollaterals[i];
            uint256 price= oraclePrices[address(coll)];
            totalCollValue += (vault.collaterals[coll]*price); 
        }
        for (uint256 i = 0; i < allowedLoans.length; i++) {
            LoanToken token = allowedLoans[i];
            uint256 price= oraclePrices[address(token)];
            uint256 usedValue= vault.loans[token];
            if(vault.loans[token] > 0) {
                usedValue += (usedValue*interestToApply)/(10**18);
            }
            totalLoanValue += (usedValue*price);
        }
        if(totalLoanValue == 0) {
            return -1;
        }
        return int(100*totalCollValue/totalLoanValue);
    }
    
    function getCollRatioForVaultWithDelta(uint256 vaultId,address collToken, uint256 removedColl, address loanToken, uint256 addLoan) internal view returns(int collRatio) {
        Vault storage vault= getVault(vaultId);
        uint256 totalCollValue= 0;
        uint256 totalLoanValue= 0;
        uint256 interestToApply= vault.scheme.interestRatePerSecond*(block.timestamp - vault.lastInterestUpdateTStamp);
        for (uint256 i = 0; i < allowedCollaterals.length; i++) {
            IERC20 coll= allowedCollaterals[i];
            uint256 price= oraclePrices[address(coll)];
            uint256 usedAmount= vault.collaterals[coll];
            if(collToken == address(coll)) {
                if(usedAmount < removedColl) {
                    usedAmount = 0;
                } else {
                    usedAmount -= removedColl;
                }
            }
            totalCollValue += (usedAmount*price); 
        }
        for (uint256 i = 0; i < allowedLoans.length; i++) {
            LoanToken token = allowedLoans[i];
            uint256 price= oraclePrices[address(token)];
            uint256 usedAmount= vault.loans[token];
            if(vault.loans[token] > 0) {
                usedAmount += (usedAmount*interestToApply)/(10**18);
            }
            if(loanToken == address(token)) {
                usedAmount += addLoan;
            }
            totalLoanValue += (usedAmount*price);
        }
        if(totalLoanValue == 0) {
            return -1;
        }
        return int(100*totalCollValue/totalLoanValue);
    }
}
