// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISocketMessageTracker {
    function messageExecuted(bytes32 messageId) external view returns (bool);
}
