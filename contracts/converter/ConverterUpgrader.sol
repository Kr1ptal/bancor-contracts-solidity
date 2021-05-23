// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.6.12;

import "../utility/ContractRegistryClient.sol";

import "../token/ReserveToken.sol";

import "./interfaces/IConverter.sol";
import "./interfaces/IConverterUpgrader.sol";
import "./interfaces/IConverterFactory.sol";

interface ILegacyConverterVersion45 is IConverter {
    function withdrawTokens(
        IReserveToken token,
        address recipient,
        uint256 amount
    ) external;

    function withdrawETH(address payable recipient) external;
}

/**
 * @dev This contract contract allows upgrading an older converter contract (0.4 and up)
 * to the latest version.
 * To begin the upgrade process, simply execute the 'upgrade' function.
 * At the end of the process, the ownership of the newly upgraded converter will be transferred
 * back to the original owner and the original owner will need to execute the 'acceptOwnership' function.
 *
 * The address of the new converter is available in the ConverterUpgrade event.
 *
 * Note that for older converters that don't yet have the 'upgrade' function, ownership should first
 * be transferred manually to the ConverterUpgrader contract using the 'transferOwnership' function
 * and then the upgrader 'upgrade' function should be executed directly.
 */
contract ConverterUpgrader is IConverterUpgrader, ContractRegistryClient {
    using ReserveToken for IReserveToken;

    /**
     * @dev triggered when the contract accept a converter ownership
     *
     * @param converter converter address
     * @param owner new owner - local upgrader address
     */
    event ConverterOwned(IConverter indexed converter, address indexed owner);

    /**
     * @dev triggered when the upgrading process is done
     *
     * @param oldConverter old converter address
     * @param newConverter new converter address
     */
    event ConverterUpgrade(address indexed oldConverter, address indexed newConverter);

    /**
     * @dev initializes a new ConverterUpgrader instance
     *
     * @param registry address of a contract registry contract
     */
    constructor(IContractRegistry registry) public ContractRegistryClient(registry) {}

    /**
     * @dev upgrades an old converter to the latest version
     * will throw if ownership wasn't transferred to the upgrader before calling this function.
     * ownership of the new converter will be transferred back to the original owner.
     * fires the ConverterUpgrade event upon success.
     * can only be called by a converter
     *
     * @param version old converter version
     */
    function upgrade(bytes32 version) external override {
        upgradeOld(IConverter(msg.sender), version);
    }

    /**
     * @dev upgrades an old converter to the latest version
     * will throw if ownership wasn't transferred to the upgrader before calling this function.
     * ownership of the new converter will be transferred back to the original owner.
     * fires the ConverterUpgrade event upon success.
     * can only be called by a converter
     *
     * @param version old converter version
     */
    function upgrade(uint16 version) external override {
        upgrade(IConverter(msg.sender), version);
    }

    /**
     * @dev upgrades an old converter to the latest version
     * will throw if ownership wasn't transferred to the upgrader before calling this function.
     * ownership of the new converter will be transferred back to the original owner.
     * fires the ConverterUpgrade event upon success.
     *
     * @param converter old converter contract address
     */
    function upgradeOld(
        IConverter converter,
        bytes32 /* version */
    ) public {
        // the upgrader doesn't require the version for older converters
        upgrade(converter, 0);
    }

    /**
     * @dev upgrades an old converter to the latest version
     * will throw if ownership wasn't transferred to the upgrader before calling this function.
     * ownership of the new converter will be transferred back to the original owner.
     * fires the ConverterUpgrade event upon success.
     *
     * @param converter old converter contract address
     * @param version old converter version
     */
    function upgrade(IConverter converter, uint16 version) private {
        address prevOwner = converter.owner();
        acceptConverterOwnership(converter);
        IConverter newConverter = createConverter(converter);
        copyReserves(converter, newConverter);
        copyConversionFee(converter, newConverter);
        transferReserveBalances(converter, newConverter, version);
        IConverterAnchor anchor = converter.token();

        if (anchor.owner() == address(converter)) {
            converter.transferTokenOwnership(address(newConverter));
            newConverter.acceptAnchorOwnership();
        }

        converter.transferOwnership(prevOwner);
        newConverter.transferOwnership(prevOwner);

        newConverter.onUpgradeComplete();

        emit ConverterUpgrade(address(converter), address(newConverter));
    }

    /**
     * @dev the first step when upgrading a converter is to transfer the ownership to the local contract.
     * the upgrader contract then needs to accept the ownership transfer before initiating
     * the upgrade process.
     * fires the ConverterOwned event upon success
     *
     * @param oldConverter converter to accept ownership of
     */
    function acceptConverterOwnership(IConverter oldConverter) private {
        oldConverter.acceptOwnership();

        emit ConverterOwned(oldConverter, address(this));
    }

    /**
     * @dev creates a new converter with same basic data as the original old converter
     * the newly created converter will have no reserves at this step.
     *
     * @param oldConverter old converter contract address
     *
     * @return new converter's contract address
     */
    function createConverter(IConverter oldConverter) private returns (IConverter) {
        IConverterAnchor anchor = oldConverter.token();
        uint32 maxConversionFee = oldConverter.maxConversionFee();
        uint16 reserveTokenCount = oldConverter.connectorTokenCount();

        // determine new converter type
        uint16 newType = 0;
        // new converter - get the type from the converter itself
        if (isV28OrHigherConverter(oldConverter)) {
            newType = oldConverter.converterType();
        } else {
            assert(reserveTokenCount > 1);
            newType = 1;
        }

        if (newType == 1 && reserveTokenCount == 2) {
            (, uint32 weight0, , , ) = oldConverter.connectors(oldConverter.connectorTokens(0));
            (, uint32 weight1, , , ) = oldConverter.connectors(oldConverter.connectorTokens(1));
            if (weight0 == PPM_RESOLUTION / 2 && weight1 == PPM_RESOLUTION / 2) {
                newType = 3;
            }
        }

        IConverterFactory converterFactory = IConverterFactory(addressOf(CONVERTER_FACTORY));
        IConverter converter = converterFactory.createConverter(newType, anchor, registry(), maxConversionFee);

        converter.acceptOwnership();

        return converter;
    }

    /**
     * @dev copies the reserves from the old converter to the new one.
     * note that this will not work for an unlimited number of reserves due to block gas limit constraints.
     *
     * @param oldConverter old converter contract address
     * @param newConverter new converter contract address
     */
    function copyReserves(IConverter oldConverter, IConverter newConverter) private {
        uint16 reserveTokenCount = oldConverter.connectorTokenCount();

        for (uint16 i = 0; i < reserveTokenCount; i++) {
            IReserveToken reserveAddress = oldConverter.connectorTokens(i);
            (, uint32 weight, , , ) = oldConverter.connectors(reserveAddress);

            newConverter.addReserve(reserveAddress, weight);
        }
    }

    /**
     * @dev copies the conversion fee from the old converter to the new one
     *
     * @param oldConverter old converter contract address
     * @param newConverter new converter contract address
     */
    function copyConversionFee(IConverter oldConverter, IConverter newConverter) private {
        uint32 conversionFee = oldConverter.conversionFee();
        newConverter.setConversionFee(conversionFee);
    }

    /**
     * @dev transfers the balance of each reserve in the old converter to the new one.
     * note that the function assumes that the new converter already has the exact same number of reserves
     * also, this will not work for an unlimited number of reserves due to block gas limit constraints.
     *
     * @param oldConverter old converter contract address
     * @param newConverter new converter contract address
     * @param version old converter version
     */
    function transferReserveBalances(
        IConverter oldConverter,
        IConverter newConverter,
        uint16 version
    ) private {
        if (version <= 45) {
            transferReserveBalancesVersion45(ILegacyConverterVersion45(address(oldConverter)), newConverter);

            return;
        }

        oldConverter.transferReservesOnUpgrade(address(newConverter));
    }

    /**
     * @dev transfers the balance of each reserve in the old converter to the new one.
     * note that the function assumes that the new converter already has the exact same number of reserves
     * also, this will not work for an unlimited number of reserves due to block gas limit constraints.
     *
     * @param oldConverter old converter contract address
     * @param newConverter new converter contract address
     */
    function transferReserveBalancesVersion45(ILegacyConverterVersion45 oldConverter, IConverter newConverter) private {
        uint16 reserveTokenCount = oldConverter.connectorTokenCount();
        for (uint16 i = 0; i < reserveTokenCount; i++) {
            IReserveToken reserveToken = oldConverter.connectorTokens(i);

            uint256 reserveBalance = reserveToken.balanceOf(address(oldConverter));
            if (reserveBalance > 0) {
                if (reserveToken.isNativeToken()) {
                    oldConverter.withdrawETH(address(newConverter));
                } else {
                    oldConverter.withdrawTokens(reserveToken, address(newConverter), reserveBalance);
                }
            }
        }
    }

    bytes4 private constant IS_V28_OR_HIGHER_FUNC_SELECTOR = bytes4(keccak256("isV28OrHigher()"));

    // using a static call to identify converter version
    // can't rely on the version number since the function had a different signature in older converters
    function isV28OrHigherConverter(IConverter converter) internal view returns (bool) {
        bytes memory data = abi.encodeWithSelector(IS_V28_OR_HIGHER_FUNC_SELECTOR);
        (bool success, bytes memory returnData) = address(converter).staticcall{ gas: 4000 }(data);

        if (success && returnData.length == 32) {
            return abi.decode(returnData, (bool));
        }

        return false;
    }
}
