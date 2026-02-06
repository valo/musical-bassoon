// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IActionVerifier} from "v2-matching/src/interfaces/IActionVerifier.sol";

interface ICollarTSA {
    struct CollarTSAParams {
        uint256 minSignatureExpiry;
        uint256 maxSignatureExpiry;
        uint256 optionVolSlippageFactor;
        uint256 callMaxDelta;
        int256 maxNegCash;
        uint256 optionMinTimeToExpiry;
        uint256 optionMaxTimeToExpiry;
        uint256 putMaxPriceFactor;
    }

    function signActionData(IActionVerifier.Action memory action, bytes memory extraData) external;
    function getCollarTSAParams() external view returns (CollarTSAParams memory);
    function getCollarTSAAddresses() external view returns (address, address, address, address, address, address);
    function getBaseTSAAddresses()
        external
        view
        returns (address, address, address, address, address, address, address);
    function subAccount() external view returns (uint256);
}
