pragma solidity 0.8.4;
pragma experimental ABIEncoderV2;

interface IContractRegistry {
    function addressOf(bytes32 contractName) external view returns (address);
}

interface IOwned {
    function owner() external view returns (address);
}

interface IConverterRegistry {
    function getAnchors() external view returns (address[] memory);
}

interface IConverter is IOwned {
    function converterType() external pure returns (uint16);

    function reserveTokens() external view returns (address[] memory);

    function reserveBalance(address reserveToken) external view returns (uint256);

    function conversionFee() external pure returns (uint32);
}

interface IBancorConverter is IOwned {
    function converterType() external pure returns (string memory);

    function connectorTokens(uint256 _index) external pure returns (address);

    function conversionFee() external pure returns (uint32);

    function getConnectorBalance(address _connectorToken) external view returns (uint256);
}

contract BancorPoolLens {
    IContractRegistry private constant CONTRACT_REGISTRY = IContractRegistry(address(0x52Ae12ABe5D8BD778BD5397F99cA900624CfADD4));
    bytes32 internal constant BANCOR_CONVERTER_REGISTRY = "BancorConverterRegistry";
    string internal constant BANCOR_TYPE = "bancor";

    struct BancorLP {
        address anchor;
        address converter;
        address token0;
        address token1;
        uint256 reservesToken0;
        uint256 reservesToken1;
        uint32 conversionFee;
    }

    function getPoolSnapshots() public view returns (BancorLP[] memory) {
        address converterRegistryAddress = CONTRACT_REGISTRY.addressOf(BANCOR_CONVERTER_REGISTRY);
        IConverterRegistry converterRegistry = IConverterRegistry(converterRegistryAddress);
        address[] memory anchors = converterRegistry.getAnchors();
        BancorLP[] memory snapshots = new BancorLP[](anchors.length);
        for(uint i=0; i<anchors.length; i++) {
            snapshots[i] = getAnchorSnapshot(anchors[i]);
        }
        return snapshots;
    }

    function getAnchorSnapshot(address anchorAddress) public view returns (BancorLP memory) {
        IOwned anchor = IOwned(anchorAddress);
        return getConverterSnapshot(anchorAddress, anchor.owner());
    }

    function getConverterSnapshot(address anchorAddress, address converterAddress) public view returns (BancorLP memory) {
        IBancorConverter bancorConverter = IBancorConverter(converterAddress);
        IConverter converter = IConverter(payable(converterAddress));

        (bool success, bytes memory returnData) = address(converterAddress).staticcall(abi.encodeWithSignature("converterType()"));

        BancorLP memory bancorLp;
        bancorLp.anchor = address(anchorAddress);
        bancorLp.converter = address(bancorConverter);
        if(success) {
            if(toUint256(returnData) == 1) {
                parseTypeOtherConverter(bancorConverter, bancorLp);
            }  else if(toUint256(returnData) == 3) {
                parseTypeThreeConverter(converter, bancorLp);
            } else if (compare(bancorConverter.converterType(),BANCOR_TYPE) == 0) {
                parseTypeOtherConverter(bancorConverter, bancorLp);
            }
        } else {
            parseTypeOtherConverter(bancorConverter, bancorLp);
        }

        return bancorLp;
    }

    function parseTypeOtherConverter(IBancorConverter converter, BancorLP memory bancorLp) private view  {
        bancorLp.token0 = converter.connectorTokens(0);
        bancorLp.token1 = converter.connectorTokens(1);
        bancorLp.reservesToken0 = converter.getConnectorBalance(bancorLp.token0);
        bancorLp.reservesToken1 = converter.getConnectorBalance(bancorLp.token1);
        bancorLp.conversionFee = converter.conversionFee();
    }

    function parseTypeThreeConverter(IConverter converter, BancorLP memory bancorLp) private view  {
        bancorLp.token0 = converter.reserveTokens()[0];
        bancorLp.token1 = converter.reserveTokens()[1];
        bancorLp.reservesToken0 = converter.reserveBalance(bancorLp.token0);
        bancorLp.reservesToken1 = converter.reserveBalance(bancorLp.token1);
        bancorLp.conversionFee = converter.conversionFee();
    }

    function toUint256(bytes memory _bytes) internal pure returns (uint256 value) {
        assembly {
          value := mload(add(_bytes, 0x20))
        }
    }

    /// @dev Does a byte-by-byte lexicographical comparison of two strings.
    /// @return a negative number if `_a` is smaller, zero if they are equal
    /// and a positive numbe if `_b` is smaller.
    function compare(string memory _a, string memory _b) private pure returns (int) {
        bytes memory a = bytes(_a);
        bytes memory b = bytes(_b);
        uint minLength = a.length;
        if (b.length < minLength) minLength = b.length;
        //@todo unroll the loop into increments of 32 and do full 32 byte comparisons
        for (uint i = 0; i < minLength; i ++)
            if (a[i] < b[i])
                return -1;
            else if (a[i] > b[i])
                return 1;
        if (a.length < b.length)
            return -1;
        else if (a.length > b.length)
            return 1;
        else
            return 0;
    }
}
