// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMatching} from "v2-matching/src/interfaces/IMatching.sol";

contract MockMatching {
    bytes32 private immutable domain;

    constructor(bytes32 domainSeparator_) {
        domain = domainSeparator_;
    }

    function domainSeparator() external view returns (bytes32) {
        return domain;
    }

    function getActionHash(IMatching.Action memory action) external pure returns (bytes32) {
        return keccak256(
            abi.encode(
                action.subaccountId,
                action.nonce,
                action.module,
                keccak256(action.data),
                action.expiry,
                action.owner,
                action.signer
            )
        );
    }
}
