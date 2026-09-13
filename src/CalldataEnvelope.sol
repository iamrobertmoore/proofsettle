// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Reads envelope || uint32(length) || "PSE1" from transaction calldata.
library CalldataEnvelope {
    error MalformedEnvelope();

    function read(bytes calldata data, uint256 minimumStart) internal pure returns (bytes calldata) {
        if (data.length < minimumStart + 8 || bytes4(data[data.length - 4:]) != 0x50534531) {
            return data[0:0];
        }
        uint256 size = uint32(bytes4(data[data.length - 8:data.length - 4]));
        if (size == 0 || size > data.length - minimumStart - 8) revert MalformedEnvelope();
        return data[data.length - 8 - size:data.length - 8];
    }
}
