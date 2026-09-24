// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Runtime bytecode scan mirroring the admission floor: steps over PUSH immediates and rejects
/// DELEGATECALL, CALLCODE and SELFDESTRUCT.
library Opcodes {
    function assertNoEscapeHatch(bytes memory code) internal pure {
        require(code.length > 0, "no runtime code");
        require(code.length <= 24_576, "over EIP-170");
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            require(op != 0xff, "SELFDESTRUCT");
            require(op != 0xf4, "DELEGATECALL");
            require(op != 0xf2, "CALLCODE");
        }
    }
}
