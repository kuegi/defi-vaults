# defi-vaults
A PoC of a vaultsystem in solidity. Done for educational purposes so I learn more about solidity.

# deploy and usage

so far its just a simple PoC. Best to deploy it via Remix. After deploying of the Vaults contract, add the ERC20 tokens you want to use as collateral via `addPossibleCollateral(<tokenAddress>)`. Also set the oracle to be used via `setOracle(<oracleAddress>)`.

This oracleAddress can now set oraclePrices per ERC20 token (coll or loan) via `setOraclePrices([["<tokenAddress>",price],["<otherToken>",otherPrice],...])`.

To create new possibleLoanTokens, use `createLoanToken("name","symbol")` which creates a LoanToken, owned by the Vaults and adds it as possible LoanToken.

## Vault
Anyone can create a vault via `createVault(0)`, 0 is the idx of the VaultScheme. On default Vaults creates 1 scheme (index 0) with 150% min ratio and 5% APR interest rate. The result of createVault is your newly created vaultId.


`addCollateral(vaultId,collTokenAddress,amount)` adds collateral to this vault. You need to make sure that your allowance of this token for the Vaults SC is high enough.

`removeCollateral(vaultId, collTokenAddress, amount)` removes collateral from the vault. can only be called by the owner of the vault

`takeLoan(vaultId, loanTokenAddress, amount)` takes a loan in the given token, this mints new coins of this token and adds it to your balance. can only be called by the owner of the vault

`paybackLoan(vaultId, loanTokenAddress, amount)` pays back an open loan in this vault. the corresponding tokens are burned directly from the senders account. This does not need any allowance (cause Loantokens are owned by Vaults).

Note that `takeLoan`, `paybackLoan` always adds all accumulated interest to the loanValue.

## Liquidation
If a vaults collateral Ratio falls below the minimum Collateral Ratio defined in the vault-scheme, it can be liquidated from anyone by calling `liquidateVault(vaultId)`. If the vault can be liquidated, all open loans (including interest) are paid back with funds from the senders address (if there are not enough funds, the tx fails) and all collateral from the vault is transferred to the sender.

