// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import './LoanToken.sol';

error InvalidCollateral();
error InvalidLoan();
error VaultNotFound();
error VaultClosed();
error NotOwner();
error InvalidScheme();

contract VaultSystem {
    struct VaultScheme {
        uint256 interestRatePerSecond; // e18
        uint minCollateralRatio; // in percent
    }

    struct Vault {
        uint256 id;
        VaultScheme scheme;
        address owner;
        uint256 lastInterestUpdateTStamp;
        mapping(address => uint256) collaterals;
        mapping(address => uint256) loans;
    }

    address private owner;

    uint256 internal nextVaultId;
    mapping(uint256 => Vault) public vaults;
    mapping(address => uint256[]) public vaultsByOwner;

    IERC20[] public allCollaterals;
    LoanToken[] public allLoans;
    mapping(address => bool) public allowedCollateral;
    mapping(address => bool) public allowedLoan;
    VaultScheme[] public possibleSchemes;

    mapping(address => uint256) public oraclePrices;
    address private oracle;

    constructor() {
        owner = msg.sender;
        nextVaultId = 1;
        possibleSchemes.push(VaultScheme(1585489599, 150)); //5% APR
    }

    function setOracle(address newOracle) external {
        require(msg.sender == owner, 'Only owner can add possible collateral');
        oracle = newOracle;
    }

    struct OraclePrice {
        address tokenAddress;
        uint256 price;
    }

    //encode parameter like this: [["0xaddressOfToken",1234],["0xaddressOfNextToken",5678]]
    function setOraclePrices(OraclePrice[] calldata prices) external {
        require(msg.sender == oracle, 'Only oracle can set prices');
        for (uint256 i = 0; i < prices.length; i++) {
            OraclePrice calldata price = prices[i];
            oraclePrices[price.tokenAddress] = price.price;
        }
    }

    function addPossibleCollateral(IERC20 token) external {
        require(msg.sender == owner, 'Only owner can add possible collateral');
        allowedCollateral[address(token)] = true;
        //ensure its no duplicate
        bool foundIt = false;
        for (uint256 i = 0; i < allCollaterals.length; i++) {
            if (allCollaterals[i] == token) {
                foundIt = true;
                break;
            }
        }
        if (!foundIt) {
            allCollaterals.push(token);
        }
    }

    function createLoanToken(string memory _name, string memory _symbol) external returns (address token) {
        require(msg.sender == owner, 'Only owner can add loanToken');
        LoanToken newToken = new LoanToken(_name, _symbol);
        allLoans.push(newToken);
        allowedLoan[address(newToken)] = true;
        return address(newToken);
    }

    //======================== vaults =====================

    function createVault(uint256 scheme) external returns (uint256 id) {
        if (scheme >= possibleSchemes.length) {
            revert InvalidScheme();
        }
        uint256 vaultId = nextVaultId++;
        Vault storage vault = vaults[vaultId];
        vault.id = vaultId;
        vault.scheme = possibleSchemes[scheme];
        vault.owner = msg.sender;
        vault.lastInterestUpdateTStamp = block.timestamp;
        vaultsByOwner[msg.sender].push(vault.id);
        return vaultId;
    }

    function getVaultValues(uint256 vaultId) public view returns (uint256 collValue, uint256 loanValue, int collRatio) {
        return getValuesForVaultWithDelta(vaultId, address(0x0), 0, address(0x0), 0);
    }

    function addCollateral(uint256 vaultId, IERC20 token, uint256 _amount) external {
        require(_amount > 0, 'cant add 0');
        Vault storage vault = getVault(vaultId); //no need to check for owner. anyone can add collateral
        if (!allowedCollateral[address(token)]) {
            revert InvalidCollateral();
        }
        token.transferFrom(msg.sender, address(this), _amount);
        vault.collaterals[address(token)] += _amount;
    }

    function removeCollateral(uint256 vaultId, IERC20 token, uint256 amount) external returns (uint256 usedAmount) {
        require(amount > 0, 'cant withdraw 0');
        Vault storage vault = getOwnedVault(vaultId);
        uint256 coll = vault.collaterals[address(token)];
        (, , int newRatio) = getValuesForVaultWithDelta(vaultId, address(token), amount, address(0x0), 0);
        require(newRatio < 0 || uint(newRatio) >= vault.scheme.minCollateralRatio, 'minCollRatio must be met');
        require(coll > 0, "can't withdraw if not there");
        if (coll < amount) {
            amount = coll;
        }
        token.transfer(msg.sender, amount);
        vault.collaterals[address(token)] -= amount;
        return amount;
    }

    function paybackLoan(uint256 vaultId, LoanToken token, uint256 amount) external returns (uint256 paid) {
        //token and amount in msg.data
        require(amount > 0, 'cant payback 0');
        Vault storage vault = getVault(vaultId); //no need to check for owner. anyone can payback loans
        uint256 openLoan = vault.loans[address(token)];
        updateInterest(vaultId);
        require(openLoan > 0, "can't payback empty loan");
        if (openLoan < amount) {
            amount = openLoan;
        }
        token.burn(msg.sender, amount);
        vault.loans[address(token)] -= amount;
        return amount;
    }

    function takeLoan(uint256 vaultId, LoanToken token, uint256 amount) external {
        Vault storage vault = getOwnedVault(vaultId);
        require(amount > 0, 'cant take 0 loan');

        if (!allowedLoan[address(token)]) {
            revert InvalidLoan();
        }
        updateInterest(vaultId);
        (, , int newRatio) = getValuesForVaultWithDelta(vaultId, address(0x0), 0, address(token), amount);
        require(uint(newRatio) >= vault.scheme.minCollateralRatio, 'minCollRatio must be met');
        token.mint(msg.sender, amount);
        vault.loans[address(token)] += amount;
    }

    //======================== liquidations =====================

    function liquidateVault(uint256 vaultId) external {
        Vault storage vault = getVault(vaultId);
        int ratio = getCollRatioForVault(vaultId);
        require(ratio > 0 && uint(ratio) < vault.scheme.minCollateralRatio, 'Can only liquidate if ratio below min');
        updateInterest(vaultId);

        for (uint256 i = 0; i < allLoans.length; i++) {
            LoanToken token = allLoans[i];
            if (vault.loans[address(token)] > 0) {
                //sender needs to payback loan
                token.burn(msg.sender, vault.loans[address(token)]); //fails if msg.sender doesn't have the coins. right?!
                vault.loans[address(token)] = 0;
            }
        }
        for (uint256 i = 0; i < allCollaterals.length; i++) {
            IERC20 coll = allCollaterals[i];
            if (vault.collaterals[address(coll)] > 0) {
                coll.transfer(msg.sender, vault.collaterals[address(coll)]);
                vault.collaterals[address(coll)] = 0;
            }
        }
    }

    //==================================================================
    // internals

    function getVault(uint256 vaultId) internal view returns (Vault storage v) {
        if (vaultId >= nextVaultId) {
            revert VaultNotFound();
        }
        Vault storage vault = vaults[vaultId];
        if (vault.id != vaultId) {
            revert VaultClosed();
        }
        return vault;
    }

    function getOwnedVault(uint256 vaultId) internal view returns (Vault storage v) {
        Vault storage vault = getVault(vaultId);
        if (vault.owner != msg.sender) {
            revert NotOwner();
        }
        return vault;
    }

    function updateInterest(uint256 vaultId) private {
        Vault storage vault = getVault(vaultId);
        uint256 interestToApply = vault.scheme.interestRatePerSecond *
            (block.timestamp - vault.lastInterestUpdateTStamp);
        for (uint256 i = 0; i < allLoans.length; i++) {
            LoanToken token = allLoans[i];
            if (vault.loans[address(token)] > 0) {
                vault.loans[address(token)] += (vault.loans[address(token)] * interestToApply) / (10 ** 18);
            }
        }
        vault.lastInterestUpdateTStamp = block.timestamp;
    }

    function getCollRatioForVault(uint256 vaultId) public view returns (int collRatio) {
        (, , int ratio) = getValuesForVaultWithDelta(vaultId, address(0x0), 0, address(0x0), 0);
        return ratio;
    }

    function getValuesForVaultWithDelta(
        uint256 vaultId,
        address collToken,
        uint256 removedColl,
        address loanToken,
        uint256 addLoan
    ) internal view returns (uint256 collValue, uint256 loanValue, int collRatio) {
        Vault storage vault = getVault(vaultId);
        uint256 totalCollValue = 0;
        uint256 totalLoanValue = 0;
        uint256 interestToApply = vault.scheme.interestRatePerSecond *
            (block.timestamp - vault.lastInterestUpdateTStamp);
        for (uint256 i = 0; i < allCollaterals.length; i++) {
            IERC20 coll = allCollaterals[i];
            uint256 price = oraclePrices[address(coll)];
            uint256 usedAmount = vault.collaterals[address(coll)];
            if (collToken == address(coll)) {
                if (usedAmount < removedColl) {
                    usedAmount = 0;
                } else {
                    usedAmount -= removedColl;
                }
            }
            totalCollValue += (usedAmount * price) / (10 ** 18);
        }
        for (uint256 i = 0; i < allLoans.length; i++) {
            LoanToken token = allLoans[i];
            uint256 price = oraclePrices[address(token)];
            uint256 usedAmount = vault.loans[address(token)];
            if (vault.loans[address(token)] > 0) {
                usedAmount += (usedAmount * interestToApply) / (10 ** 18);
            }
            if (loanToken == address(token)) {
                usedAmount += addLoan;
            }
            totalLoanValue += (usedAmount * price) / (10 ** 18);
        }
        if (totalLoanValue == 0) {
            return (totalCollValue, totalLoanValue, -1);
        }
        return (totalCollValue, totalLoanValue, int((100 * totalCollValue) / totalLoanValue));
    }
}
