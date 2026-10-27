# fusi.ng V2

The second release (15 September 2026): payout modes, creator lock and vesting, burn and liquidity vaults, multi-pool launches.

Solidity smart contracts of [fusi.ng](https://fusi.ng), a token launchpad on Ethereum built on Uniswap V4. Ethereum mainnet only.

- Website: https://fusi.ng
- Docs and ABIs: https://fusi.ng/docs#tech
- X: https://x.com/fusi_ng
- Telegram: https://t.me/fusi_ng

## Deployed contracts (Ethereum mainnet)

| Role | Address | Contract | Source status |
| --- | --- | --- | --- |
| burnVaultFactory | [`0x0A7c3a812f379149d8661A3EF4ECc3673c88519c`](https://etherscan.io/address/0x0A7c3a812f379149d8661A3EF4ECc3673c88519c) | FusingBurnVaultFactory | verified on Etherscan |
| burnVaultImpl | [`0x82D64ad3598C00b843Fb3A042EFc466695873c6b`](https://etherscan.io/address/0x82D64ad3598C00b843Fb3A042EFc466695873c6b) |  | not verified |
| factory | [`0x595EA7017d4D543C8AbBb82F2365651fD9a3A42f`](https://etherscan.io/address/0x595EA7017d4D543C8AbBb82F2365651fD9a3A42f) | FusingLaunchFactory | verified on Etherscan |
| feeEscrow | [`0xaF5d6C1573fA8F7f662dc288321D5975f1c83DF6`](https://etherscan.io/address/0xaF5d6C1573fA8F7f662dc288321D5975f1c83DF6) | FusingFeeEscrow | verified on Etherscan |
| launchDeployer | [`0xf053C6f66A5B60ec1C84A829c1d990d925FDEB8C`](https://etherscan.io/address/0xf053C6f66A5B60ec1C84A829c1d990d925FDEB8C) | FusingLaunchDeployer | verified on Etherscan |
| liquidityVaultFactory | [`0xB0611E214B8E0948D915381541DD123Bf61d0171`](https://etherscan.io/address/0xB0611E214B8E0948D915381541DD123Bf61d0171) | FusingLiquidityVaultFactory | verified on Etherscan |
| liquidityVaultImpl | [`0x058810076BCE93058fD87aCdCd2939D85a3170E3`](https://etherscan.io/address/0x058810076BCE93058fD87aCdCd2939D85a3170E3) |  | not verified |
| locker | [`0x357ffD979B2D4aDd7122728b7dF1e38F2cB4cCEE`](https://etherscan.io/address/0x357ffD979B2D4aDd7122728b7dF1e38F2cB4cCEE) | FusingLaunchLocker | verified on Etherscan |
| multiFactory | [`0xA4018A1b0e073c0Cf2Ed2e819a9fC4A562CbbcCf`](https://etherscan.io/address/0xA4018A1b0e073c0Cf2Ed2e819a9fC4A562CbbcCf) | MultiFuseFactory | verified on Etherscan |
| multiLaunchDeployer | [`0x827259cEa84e4C904b9A47B1983cAd467a31b59c`](https://etherscan.io/address/0x827259cEa84e4C904b9A47B1983cAd467a31b59c) | FusingLaunchDeployer | verified on Etherscan |
| multiLocker | [`0x4E09e2bF71A670319b7931DCd4C960C0e2AB415B`](https://etherscan.io/address/0x4E09e2bF71A670319b7931DCd4C960C0e2AB415B) | MultiFuseLocker | verified on Etherscan |
| multiPositionMinter | [`0x08A7D89879f8cea7F46deF8c08185D9E011757b4`](https://etherscan.io/address/0x08A7D89879f8cea7F46deF8c08185D9E011757b4) | PairPadMultiPositionMinter | verified on Etherscan |
| multiReferenceRegistry | [`0x77ae614c569d192b5B01b7C5e4A91A4Df5914EAf`](https://etherscan.io/address/0x77ae614c569d192b5B01b7C5e4A91A4Df5914EAf) | PairPadMultiReferenceRegistry | verified on Etherscan |
| multiRouter | [`0xcDCE97d027b4cF0e40BCB600be6A43d399B81673`](https://etherscan.io/address/0xcDCE97d027b4cF0e40BCB600be6A43d399B81673) | PairPadMultiRouter | verified on Etherscan |
| positionMinter | [`0x0AEcE6eE085E91663e8ec1969F4B47Ea7222f0f6`](https://etherscan.io/address/0x0AEcE6eE085E91663e8ec1969F4B47Ea7222f0f6) | PairPadPositionMinter | verified on Etherscan |
| quotePricer | [`0xa921Ba744E5184f9373e7821fe542451eAE56E29`](https://etherscan.io/address/0xa921Ba744E5184f9373e7821fe542451eAE56E29) | FusingQuotePricer | verified on Etherscan |
| referenceRegistry | [`0x7766E6C09dbb1a262BCb17226CFbF13245D85efE`](https://etherscan.io/address/0x7766E6C09dbb1a262BCb17226CFbF13245D85efE) | V4LaunchReferenceRegistry | verified on Etherscan |
| router | [`0x4afEE70c738abFf00A655825db05D681c005Fd72`](https://etherscan.io/address/0x4afEE70c738abFf00A655825db05D681c005Fd72) | FusingRouter | verified on Etherscan |
| treasury | [`0x1B611E5D5c7053F7490BA15c8e8172a5dF52c893`](https://etherscan.io/address/0x1B611E5D5c7053F7490BA15c8e8172a5dF52c893) | FusingTreasury | verified on Etherscan |
| v1ReferenceRegistry | [`0xdffa1699F7e8dc67F05d023b70C1dF85cD361503`](https://etherscan.io/address/0xdffa1699F7e8dc67F05d023b70C1dF85cD361503) | V4LaunchReferenceRegistry | verified on Etherscan |

## Source note

Every file here is exactly the source verified on Etherscan for the contracts above. Where two contracts in this stack were compiled from different revisions of the same file, the second revision is kept under `variants/<role>/`. Third-party libraries (Uniswap V4, OpenZeppelin and others) are not included; their exact versions are part of each contract's verified bundle on Etherscan.

Compiler: solc 0.8.26. Exact compiler settings are in each verified contract on Etherscan.

## License

MIT, as declared in each file's SPDX header.
