// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

library SafeCast {
    error SafeCast__Overflow();

    function toUint112(uint256 value) internal pure returns (uint112) {
        if (value > type(uint112).max) revert SafeCast__Overflow();
        return uint112(value);
    }

    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert SafeCast__Overflow();
        return uint128(value);
    }
}
