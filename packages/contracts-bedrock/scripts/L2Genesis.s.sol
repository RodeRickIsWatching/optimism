// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Predeploys } from "src/libraries/Predeploys.sol";
import { Preinstalls } from "src/libraries/Preinstalls.sol";

import { L2StandardBridge } from "src/L2/L2StandardBridge.sol";
import { L2CrossDomainMessenger } from "src/L2/L2CrossDomainMessenger.sol";
import { L1CrossDomainMessenger } from "src/L1/L1CrossDomainMessenger.sol";
import { L1StandardBridge } from "src/L1/L1StandardBridge.sol";
import { SequencerFeeVault } from "src/L2/SequencerFeeVault.sol";
import { FeeVault } from "src/universal/FeeVault.sol";
import { OptimismMintableERC20Factory } from "src/universal/OptimismMintableERC20Factory.sol";
import { GovernanceToken } from "src/governance/GovernanceToken.sol";
import { DeployConfig } from "scripts/DeployConfig.s.sol";
import { Artifacts } from "scripts/Artifacts.s.sol";

interface IInitializable {
    function initialize() external;
}

// @title
contract L2Genesis is Script, Artifacts {
    uint256 constant PROXY_COUNT = 2048;
    uint256 constant PRECOMPILE_COUNT = 256;
    DeployConfig public constant cfg =
        DeployConfig(address(uint160(uint256(keccak256(abi.encode("optimism.deployconfig"))))));

    /// @notice The storage slot that holds the address of a proxy implementation.
    /// @dev `bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)`
    bytes32 internal constant PROXY_IMPLEMENTATION_ADDRESS =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The storage slot that holds the address of the owner.
    /// @dev `bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1)`
    bytes32 internal constant PROXY_ADMIN_ADDRESS = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    mapping(string => address) deployments;

    string outfile;

    struct OptimismConfig {
        uint eip1559Elasticity;
        uint eip1559Denominator;
        uint eip1559DenominatorCanyon;
    }

    struct ChainConfig {
        uint chainId;
        uint homesteadBlock;
        uint eip150Block;
        uint eip155Block;
        uint eip158Block;
        uint byzantiumBlock;
        uint constantinopleBlock;
        uint petersburgBlock;
        uint istanbulBlock;
        uint muirGlacierBlock;
        uint berlinBlock;
        uint londonBlock;
        uint arrowGlacierBlock;
        uint grayGlacierBlock;
        uint mergeNetsplitBlock;
        uint shanghaiTime;
        uint bedrockBlock;
        uint regolithTime;
        uint canyonTime;
        uint terminalTotalDifficulty;
        bool terminalTotalDifficultyPassed;
        OptimismConfig optimism;
    }

    function setUp() public override {
        Artifacts.setUp();

        string memory path = string.concat(vm.projectRoot(), "/deploy-config/", deploymentContext, ".json");
        vm.etch(address(cfg), vm.getDeployedCode("DeployConfig.s.sol:DeployConfig"));
        vm.label(address(cfg), "DeployConfig");
        vm.allowCheatcodes(address(cfg));
        cfg.read(path);

        outfile = string.concat(vm.projectRoot(), "/deployments/", deploymentContext, "/genesis.json");
        _loadAddresses(string.concat(vm.projectRoot(), "/deployments/", deploymentContext, "/.deploy"));
    }

    function run() public {
        _setPrecompiles();
        _setProxies();
        _setImplementations();
        _setPreinstalls();

        vm.dumpState(outfile);

        string memory tmpGenesisPath = string.concat(vm.projectRoot(), "/deployments/", deploymentContext, "/genesis.tmp.json");
        string[] memory addAllocsKeyToGenesiscommands = new string[](3);
        addAllocsKeyToGenesiscommands[0] = "bash";
        addAllocsKeyToGenesiscommands[1] = "-c";
        addAllocsKeyToGenesiscommands[2] = string.concat(
            "jq '{ \"alloc\": . }' ",
            outfile,
            " > ",
            tmpGenesisPath
        );
        vm.ffi(addAllocsKeyToGenesiscommands);

        string[] memory updateGenesisOutFileCommands = new string[](3);
        updateGenesisOutFileCommands[0] = "bash";
        updateGenesisOutFileCommands[1] = "-c";
        updateGenesisOutFileCommands[2] = string.concat(
            "mv -f ",
            tmpGenesisPath,
            " ",
            outfile
        );
        vm.ffi(updateGenesisOutFileCommands);

        string[] memory addConfigToGenesiscommands = new string[](3);
        addConfigToGenesiscommands[0] = "bash";
        addConfigToGenesiscommands[1] = "-c";
        addConfigToGenesiscommands[2] = string.concat(
            "jq '. + ",
            "{\"config\":",
            _getChainConfig(),
            "}",
            "' ",
            outfile,
            " > ",
            tmpGenesisPath
        );
        vm.ffi(addConfigToGenesiscommands);

        vm.ffi(updateGenesisOutFileCommands);
    }

    /// @notice Give all of the precompiles 1 wei so that they are
    ///         not considered empty accounts.
    function _setPrecompiles() internal {
        for (uint256 i; i < PRECOMPILE_COUNT; i++) {
            vm.deal(address(uint160(i)), 1);
        }
    }

    /// @dev Set up the accounts that correspond to the predeploys.
    ///      The Proxy bytecode should be set. All proxied predeploys should have
    ///      the 1967 admin slot set to the ProxyAdmin predeploy. All defined predeploys
    ///      should have their implementations set.
    function _setProxies() internal {
        bytes memory code = vm.getDeployedCode("Proxy.sol:Proxy");
        uint160 prefix = uint160(0x420) << 148;
        for (uint256 i = 0; i < PROXY_COUNT; i++) {
            address addr = address(prefix | uint160(i));
            if (_notProxied(addr)) {
                continue;
            }

            vm.etch(addr, code);
            vm.store(addr, PROXY_ADMIN_ADDRESS, bytes32(uint256(uint160(Predeploys.PROXY_ADMIN))));

            if (_isDefinedPredeploy(addr)) {
                address implementation = _predeployToCodeNamespace(addr);
                vm.store(addr, PROXY_IMPLEMENTATION_ADDRESS, bytes32(uint256(uint160(implementation))));
            }
        }
    }

    /// @dev
    /// 2 options
    ///  - use getDeployedCode
    ///  - use new
    /// need to ensure that storage is correct
    /// need assert no immutables sort of check
    function _setImplementations() internal {
        _setLegacyMessagePasser();
        _setDeployerWhitelist();
        _setLegacyERC20ETH();
        _setWETH9();
        _setL2CrossDomainMessenger();
        _setL2StandardBridge();
        _setSequencerFeeVault();
        _setOptimismMintableERC20Factory();
        _setL1BlockNumber();
        _setGasPriceOracle();
        _setGovernanceToken();
        _setL1Block();
    }

    function _setLegacyMessagePasser() internal {
        address impl = _predeployToCodeNamespace(Predeploys.LEGACY_MESSAGE_PASSER);
        vm.etch(impl, vm.getDeployedCode("LegacyMessagePasser.sol:LegacyMessagePasser"));
    }

    function _setDeployerWhitelist() internal {
        address impl = _predeployToCodeNamespace(Predeploys.DEPLOYER_WHITELIST);
        vm.etch(impl, vm.getDeployedCode("DeployerWhitelist.sol:DeployerWhitelist"));
    }

    function _setLegacyERC20ETH() internal {
        // TODO: this is ignored in Go code?
    }

    // TODO Differing deployed bytecode from previous L2 genesis
    function _setWETH9() internal {
        vm.etch(
            Predeploys.WETH9,
            vm.getDeployedCode("WETH9.sol:WETH9")
        );
        vm.store(
            Predeploys.WETH9,
            hex"0000000000000000000000000000000000000000000000000000000000000000",
            hex"577261707065642045746865720000000000000000000000000000000000001a"
        );
        vm.store(
            Predeploys.WETH9,
            hex"0000000000000000000000000000000000000000000000000000000000000001",
            hex"5745544800000000000000000000000000000000000000000000000000000008"
        );
        vm.store(
            Predeploys.WETH9,
            hex"0000000000000000000000000000000000000000000000000000000000000002",
            hex"0000000000000000000000000000000000000000000000000000000000000012"
        );
    }

    function _setL2StandardBridge() internal {
        L2StandardBridge bridge = new L2StandardBridge();
        address impl = _predeployToCodeNamespace(Predeploys.L2_STANDARD_BRIDGE);

        vm.etch(impl, address(bridge).code);
        vm.store(
            Predeploys.L2_STANDARD_BRIDGE,
            hex"0000000000000000000000000000000000000000000000000000000000000000",
            hex"0000000000000000000000000000000000000000000000000000000000000001"
        );
        vm.store(
            Predeploys.L2_STANDARD_BRIDGE,
            hex"0000000000000000000000000000000000000000000000000000000000000003",
            hex"0000000000000000000000004200000000000000000000000000000000000007"
        );
        vm.store(
            Predeploys.L2_STANDARD_BRIDGE,
            hex"0000000000000000000000000000000000000000000000000000000000000004",
            hex"0000000000000000000000000c8b5822b6e02cda722174f19a1439a7495a3fa6"
        );

        vm.etch(address(bridge), hex"");
        vm.resetNonce(address(bridge));
    }

    function _setL2CrossDomainMessenger() internal {
        L2CrossDomainMessenger messenger = new L2CrossDomainMessenger();
        address impl = _predeployToCodeNamespace(Predeploys.L2_CROSS_DOMAIN_MESSENGER);

        vm.etch(impl, address(messenger).code);

        vm.store(
            Predeploys.L2_CROSS_DOMAIN_MESSENGER,
            hex"0000000000000000000000000000000000000000000000000000000000000000",
            hex"0000000000000000000000010000000000000000000000000000000000000000"
        );
        vm.store(
            Predeploys.L2_CROSS_DOMAIN_MESSENGER,
            hex"00000000000000000000000000000000000000000000000000000000000000cc",
            hex"000000000000000000000000000000000000000000000000000000000000dead"
        );
        vm.store(
            Predeploys.L2_CROSS_DOMAIN_MESSENGER,
            hex"00000000000000000000000000000000000000000000000000000000000000cd",
            hex"0000000000000000000000000000000000000000000000000000000000000000"
        );
        vm.store(
            Predeploys.L2_CROSS_DOMAIN_MESSENGER,
            hex"00000000000000000000000000000000000000000000000000000000000000cf",
            hex"00000000000000000000000020a42a5a785622c6ba2576b2d6e924aa82bfa11d"
        );

        // TODO: upstream filtering out of empty accounts?
        vm.etch(address(messenger), hex"");
        vm.resetNonce(address(messenger));
    }

    function _setSequencerFeeVault() internal {
        SequencerFeeVault vault = new SequencerFeeVault({
            _recipient: cfg.sequencerFeeVaultRecipient(),
            _minWithdrawalAmount: cfg.sequencerFeeVaultMinimumWithdrawalAmount(),
            _withdrawalNetwork: FeeVault.WithdrawalNetwork.L2
        });

        vm.etch(_predeployToCodeNamespace(Predeploys.SEQUENCER_FEE_WALLET), address(vault).code);

        vm.etch(address(vault), hex"");
        vm.resetNonce(address(vault));
    }

    function _setOptimismMintableERC20Factory() internal {
        address impl = _predeployToCodeNamespace(Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY);
        OptimismMintableERC20Factory factory = new OptimismMintableERC20Factory();

        vm.etch(impl, address(factory).code);
        vm.store(
            Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY,
            hex"0000000000000000000000000000000000000000000000000000000000000000",
            hex"0000000000000000000000000000000000000000000000000000000000000001"
        );
        vm.store(
            Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY,
            hex"0000000000000000000000000000000000000000000000000000000000000001",
            hex"0000000000000000000000004200000000000000000000000000000000000010"
        );

        vm.etch(address(factory), hex"");
        vm.resetNonce(address(factory));
    }

    function _setL1BlockNumber() internal {
        vm.etch(
            _predeployToCodeNamespace(Predeploys.L1_BLOCK_NUMBER),
            vm.getDeployedCode("L1BlockNumber.sol:L1BlockNumber")
        );
    }

    function _setGasPriceOracle() internal {
        vm.etch(
            _predeployToCodeNamespace(Predeploys.GAS_PRICE_ORACLE),
            vm.getDeployedCode("GasPriceOracle.sol:GasPriceOracle")
        );
    }

    function _setGovernanceToken() internal {
        if (!cfg.enableGovernance()) {
            console.log("Governance not enabled, skipping setting governanace token");
            return;
        }
        // TODO Transfer to cfg.finalSystemOwner?

        vm.etch(Predeploys.GOVERNANCE_TOKEN, vm.getDeployedCode("GovernanceToken.sol:GovernanceToken"));

        vm.store(
            Predeploys.GOVERNANCE_TOKEN,
            hex"0000000000000000000000000000000000000000000000000000000000000003",
            hex"4f7074696d69736d000000000000000000000000000000000000000000000010"
        );
        vm.store(
            Predeploys.GOVERNANCE_TOKEN,
            hex"0000000000000000000000000000000000000000000000000000000000000004",
            hex"4f50000000000000000000000000000000000000000000000000000000000004"
        );
        vm.store(
            Predeploys.GOVERNANCE_TOKEN,
            hex"000000000000000000000000000000000000000000000000000000000000000a",
            hex"000000000000000000000000a0ee7a142d267c1f36714e4a8f75612f20a79720"
        );
    }

    function _setL1Block() internal {
        vm.etch(
            _predeployToCodeNamespace(Predeploys.L1_BLOCK_ATTRIBUTES),
            vm.getDeployedCode("L1Block.sol:L1Block")
        );
    }

    /// @dev Sets the deployed bytecode for the Preinstalls
    function _setPreinstalls() internal {
        _setMulticall3();
        _setCreate2Deployer();
        _setSafe_v130();
        _setSafeL2_v130();
        _setMultiSendCallOnly_v130();
        _setSafeSingletonFactory();
        _setDeterministicDeploymentProxy();
        _setMultiSend_v130();
        _setPermit2();
        _setSenderCreator();
        _setEntryPoint();
    }

    function _setMulticall3() internal {
        vm.etch(Preinstalls.MULTICALL3, Preinstalls.MULTICALL3_DEPLOYED_BYTECOTE);
    }

    function _setCreate2Deployer() internal {
        vm.etch(Preinstalls.CREATE2_DEPLOYER, Preinstalls.CREATE2_DEPLOYER_DEPLOYED_BYTECOTE);
    }

    function _setSafe_v130() internal {
        vm.etch(Preinstalls.SAFE_V130, Preinstalls.SAFE_V130_DEPLOYED_BYTECOTE);
    }

    function _setSafeL2_v130() internal {
        vm.etch(Preinstalls.SAFE_L2_V130, Preinstalls.SAFE_L2_V130_DEPLOYED_BYTECOTE);
    }

    function _setMultiSendCallOnly_v130() internal {
        vm.etch(Preinstalls.MULTI_SEND_CALL_ONLY_V130, Preinstalls.MULTI_SEND_CALL_ONLY_V130_DEPLOYED_BYTECOTE);
    }

    function _setSafeSingletonFactory() internal {
        vm.etch(Preinstalls.SAFE_SINGLETON_FACTORY, Preinstalls.SAFE_SINGLETON_FACTORY_DEPLOYED_BYTECOTE);
    }

    function _setDeterministicDeploymentProxy() internal {
        vm.etch(Preinstalls.DETERMINISTIC_DEPLOYMENT_PROXY, Preinstalls.DETERMINISTIC_DEPLOYMENT_PROXY_DEPLOYED_BYTECOTE);
    }

    function _setMultiSend_v130() internal {
        vm.etch(Preinstalls.MULTI_SEND_V130, Preinstalls.MULTI_SEND_V130_DEPLOYED_BYTECOTE);
    }

    /// @notice This script MUST be invoked with the expected chain id for your L2
    ///         for the correct deployed bytecode for Permit2 to be resolved
    ///         e.g. forge script --chain-id 10 ./scripts/L2Genesis.s.sol:L2Genesis.
    /// @dev Permit2 has an immutable variable that's set to block.chainid, so we're deploying
    ///      it by calling Preinstalls.DETERMINISTIC_DEPLOYMENT_PROXY with the same CREATE2 salt
    ///      initialization bytecode used on ETH mainnet.
    function _setPermit2() internal {
        (bool success,) = Preinstalls.DETERMINISTIC_DEPLOYMENT_PROXY.call(abi.encodePacked(
            Preinstalls.PERMIT2_CREATE2_SALT,
            Preinstalls.PERMIT2_INITIALIZATION_BYTECOTE
        ));
        require(success, "Failed to deploy Permit2 via Preinstalls.DETERMINISTIC_DEPLOYMENT_PROXY");
    }

    function _setSenderCreator() internal {
        vm.etch(Preinstalls.SENDER_CREATOR, Preinstalls.SENDER_CREATOR_DEPLOYED_BYTECOTE);
    }

    function _setEntryPoint() internal {
        vm.etch(Preinstalls.ENTRY_POINT, Preinstalls.ENTRY_POINT_DEPLOYED_BYTECOTE);
    }

    /// @dev Function to compute the expected address of the predeploy implementation
    ///      in the genesis state.
    function _predeployToCodeNamespace(address _addr) internal pure returns (address) {
        return address(
            uint160(uint256(uint160(_addr)) & 0xffff | uint256(uint160(0xc0D3C0d3C0d3C0D3c0d3C0d3c0D3C0d3c0d30000)))
        );
    }

    /// @dev Returns true if the address is a predeploy.
    function _isDefinedPredeploy(address _addr) internal pure returns (bool) {
        return _addr == Predeploys.L2_TO_L1_MESSAGE_PASSER || _addr == Predeploys.L2_CROSS_DOMAIN_MESSENGER
            || _addr == Predeploys.L2_STANDARD_BRIDGE || _addr == Predeploys.L2_ERC721_BRIDGE
            || _addr == Predeploys.SEQUENCER_FEE_WALLET || _addr == Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY
            || _addr == Predeploys.OPTIMISM_MINTABLE_ERC721_FACTORY || _addr == Predeploys.L1_BLOCK_ATTRIBUTES
            || _addr == Predeploys.GAS_PRICE_ORACLE || _addr == Predeploys.DEPLOYER_WHITELIST || _addr == Predeploys.WETH9
            || _addr == Predeploys.L1_BLOCK_NUMBER || _addr == Predeploys.LEGACY_MESSAGE_PASSER
            || _addr == Predeploys.PROXY_ADMIN || _addr == Predeploys.BASE_FEE_VAULT || _addr == Predeploys.L1_FEE_VAULT
            || _addr == Predeploys.GOVERNANCE_TOKEN || _addr == Predeploys.SCHEMA_REGISTRY || _addr == Predeploys.EAS;
    }

    /// @dev Returns true if the adress is not proxied.
    function _notProxied(address _addr) internal pure returns (bool) {
        return _addr == Predeploys.GOVERNANCE_TOKEN || _addr == Predeploys.WETH9;
    }

    function _getChainConfig() internal returns (string memory) {
        // TODO Go code is using block.Time() from provided *types.Block.
        // devnetL1-template.json specifies "l2BlockTime": 2,
        // so should genesisTime = cfg.l2BlockTime?
        // block.timestamp = 1
        uint256 genesisTime = block.timestamp;

        string memory serializedConfigName = "chainConfig";
        string memory json = "";
        json = stdJson.serialize(serializedConfigName, "chainId", cfg.l2ChainID());
        json = stdJson.serialize(serializedConfigName, "homesteadBlock", uint256(0));
        // DAOForkBlock is set to nil
        json = stdJson.serialize(serializedConfigName, "DAOForkSupport", false);
        json = stdJson.serialize(serializedConfigName, "eip150Block", uint256(0));
        json = stdJson.serialize(serializedConfigName, "eip155Block", uint256(0));
        json = stdJson.serialize(serializedConfigName, "eip158Block", uint256(0));
        json = stdJson.serialize(serializedConfigName, "byzantiumBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "constantinopleBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "petersburgBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "istanbulBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "muirGlacierBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "berlinBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "londonBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "arrowGlacierBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "grayGlacierBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "mergeNetsplitBlock", uint256(0));
        json = stdJson.serialize(serializedConfigName, "terminalTotalDifficulty", uint256(0));
        json = stdJson.serialize(serializedConfigName, "terminalTotalDifficultyPassed", true);
        // TODO This was previously set as uint64, is it okay to be uint256?
        json = stdJson.serialize(serializedConfigName, "bedrockBlock", cfg.l2GenesisBlockNumber());
        json = stdJson.serialize(serializedConfigName, "regolithTime", _getHardforkTime(cfg.l2GenesisRegolithTimeOffset(), genesisTime));
        json = stdJson.serialize(serializedConfigName, "canyonTime", _getHardforkTime(cfg.l2GenesisCanyonTimeOffset(), genesisTime));


        // TODO
        json = stdJson.serialize(serializedConfigName, "shanghaiTime", uint256(0));
        // TODO
        json = stdJson.serialize(serializedConfigName, "cancunTime", uint256(0));
        // TODO
        json = stdJson.serialize(serializedConfigName, "ecotoneTime", uint256(0));
        // TODO
        json = stdJson.serialize(serializedConfigName, "interopTime", uint256(0));

        string memory serializedOptimismConfig = "optimismConfig";
        string memory nestedOptimismConfig = "";
        // TODO
        nestedOptimismConfig = stdJson.serialize(serializedOptimismConfig, "eip1559Elasticity", uint256(6));
        // TODO
        nestedOptimismConfig = stdJson.serialize(serializedOptimismConfig, "eip1559Denominator", uint256(50));
        // TODO
        nestedOptimismConfig = stdJson.serialize(serializedOptimismConfig, "eip1559DenominatorCanyon", uint256(250));

        json = stdJson.serialize(serializedConfigName, "optimism", nestedOptimismConfig);
        return json;
    }

    function _getHardforkTime(uint256 hardforkTimeOffset, uint256 genesisTime) internal pure returns(uint256) {
        uint256 _default = 0;
        if (hardforkTimeOffset > 0) {
            return genesisTime + hardforkTimeOffset;
        }
        return _default;
    }
}
