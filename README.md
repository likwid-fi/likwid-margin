## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

<https://book.getfoundry.sh/>

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Anvil

```shell
anvil
```

### Deploy

```shell
forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
source .env & forge script script/DeployHook.s.sol --broadcast --rpc-url https://ethereum-sepolia.publicnode.com --private-key $PRIKEY
## --num-of-optimizations 1000000 默认是200
forge verify-contract \
    --chain-id 11155111 \
    --evm-version cancun \
    --watch \
    --constructor-args $(cast abi-encode "constructor(address,address,address,address)" "0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1" "0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A" "0x168768C3eB60070D089F7C8fE7A2224d164C9AC6" "0x716CE8f47504bC7E6E4bd29856585a2e202a4De6") \
    --etherscan-api-key $ETHERSCAN_API_KEY_SEPOLIA \
    --compiler-version v0.8.26+commit.8a97fa7a \
    0x589F0171783738B7491d2E5aa3aA00E9034C0888 \
    src/MarginHookManager.sol:MarginHookManager
forge verify-contract \
    --chain-id 11155111 \
    --evm-version cancun \
    --watch \
    --constructor-args $(cast abi-encode "constructor(address)" "0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1") \
    --etherscan-api-key $ETHERSCAN_API_KEY_SEPOLIA \
    --compiler-version v0.8.26+commit.8a97fa7a \
    0x716CE8f47504bC7E6E4bd29856585a2e202a4De6 \
    src/MarginPositionManager.sol:MarginPositionManager
forge verify-contract \
    --chain-id 11155111 \
    --evm-version cancun \
    --watch \
    --constructor-args $(cast abi-encode "constructor(address,address,address)" "0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1" "0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A" "0x589F0171783738B7491d2E5aa3aA00E9034C0888") \
    --etherscan-api-key $ETHERSCAN_API_KEY_SEPOLIA \
    --compiler-version v0.8.26+commit.8a97fa7a \
    0x6E0EE135EcD02516cB26a8D4f7F7B8dF0b1E748D \
    src/MarginRouter.sol:MarginRouter


forge script script/DeployOracle.s.sol --broadcast --rpc-url https://ethereum-sepolia.publicnode.com --private-key $PRIKEY
forge script script/DeployFees.s.sol --broadcast --rpc-url https://ethereum-sepolia.publicnode.com --private-key $PRIKEY
forge script script/DeployMirror.s.sol --broadcast --rpc-url https://ethereum-sepolia.publicnode.com --private-key $PRIKEY

forge script script/DeployMockToken.s.sol --broadcast --rpc-url https://ethereum-sepolia.publicnode.com --private-key $PRIKEY
forge verify-contract \
    --chain-id 11155111 \
    --evm-version cancun \
    --watch \
    --constructor-args $(cast abi-encode "constructor(string,string,uint8)" "TESTA" "TESTA" 18) \
    --etherscan-api-key $ETHERSCAN_API_KEY_SEPOLIA \
    --compiler-version v0.8.26+commit.8a97fa7a \
    0x17ebA443A87a368654603F63bf5ACC3709BC9418 \
    lib/v4-periphery/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20
forge verify-contract \
    --chain-id 11155111 \
    --evm-version cancun \
    --watch \
    --constructor-args $(cast abi-encode "constructor(string,string,uint8)" "TESTB" "TESTB" 18) \
    --etherscan-api-key $ETHERSCAN_API_KEY_SEPOLIA \
    --compiler-version v0.8.26+commit.8a97fa7a \
    0x936A4dc00FEd79C5224EC60ee2d438B504d61128 \
    lib/v4-periphery/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20
```

### Cast

```shell
cast <subcommand>
```

### Help

```shell
forge --help
anvil --help
cast --help
```
