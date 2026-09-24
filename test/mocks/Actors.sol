// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PVP} from "../../src/PVP.sol";
import {PvPad} from "../../src/PvPad.sol";
import {PvPadHook} from "../../src/PvPadHook.sol";
import {PvPadFeeRouter, IBuyAndBurn} from "../../src/PvPadFeeRouter.sol";
import {WorkerSubsidy} from "../../src/WorkerSubsidy.sol";
import {KingOfThePad} from "../../src/KingOfThePad.sol";

/// @dev Refuses every ETH transfer.
contract RejectingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// @dev Accepts ETH but burns as much gas as it is given.
contract GasHog {
    receive() external payable {
        while (true) {}
    }
}

/// @dev Returns an enormous payload to any caller.
contract ReturnBomb {
    receive() external payable {
        assembly {
            return(0, 0x100000)
        }
    }
}

/// @dev A beneficiary that takes the ETH and burns nothing.
contract GreedyBeneficiary is IBuyAndBurn {
    function buyAndBurn(address) external payable {}
}

/// @dev A beneficiary that always reverts.
contract RevertingBeneficiary is IBuyAndBurn {
    function buyAndBurn(address) external payable {
        revert("nope");
    }
}

/// @dev A beneficiary that tries to re-enter the router during delivery.
contract ReenteringBeneficiary is IBuyAndBurn {
    PvPadFeeRouter public immutable router;

    constructor(PvPadFeeRouter r) {
        router = r;
    }

    function buyAndBurn(address) external payable {
        router.distribute(address(this), gasleft());
    }
}

/// @dev A beneficiary that crowns a new king with the ETH it is delivered and burns one PVP unit it
/// already holds, so the router's supply check passes. Models a beneficiary that games the king.
contract KingFlipper is IBuyAndBurn {
    KingOfThePad public immutable king;
    address public immutable next;

    constructor(KingOfThePad k, address n) {
        king = k;
        next = n;
    }

    function buyAndBurn(address token) external payable {
        king.claim{value: msg.value}(next);
        PVP(token).burn(1);
    }

    receive() external payable {}
}

/// @dev Looks like a pad to the hook, but is not the one that deployed the market.
contract FakePad {
    IPoolManager public immutable poolManager;
    address public immutable token;
    address public hook;

    constructor(IPoolManager m, address t) {
        poolManager = m;
        token = t;
    }

    function setHook(address h) external {
        hook = h;
    }

    function bind(PvPadHook target, address pvp) external {
        target.bind(address(this), pvp);
    }

    function bindAs(PvPadHook target, address padAddress, address pvp) external {
        target.bind(padAddress, pvp);
    }
}

/// @dev Has code and a `poolManager()` getter but is not a hook.
contract NotAHook {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager m) {
        poolManager = m;
    }
}

/// @dev A sell recipient that re-enters the pad while receiving its ETH.
contract ReenteringSeller {
    PvPad public immutable pad;
    bool public reentered;

    constructor(PvPad p) {
        pad = p;
    }

    receive() external payable {
        pad.buy{value: msg.value}(0, block.timestamp, address(this));
        reentered = true;
    }
}

/// @dev A worker payee that re-enters `claim` while being paid.
contract ReenteringPayee {
    WorkerSubsidy public immutable subsidy;
    uint256 id;
    uint256 amount;
    bytes32[] proof;

    constructor(WorkerSubsidy s) {
        subsidy = s;
    }

    function arm(uint256 id_, uint256 amount_, bytes32[] memory proof_) external {
        id = id_;
        amount = amount_;
        proof = proof_;
    }

    receive() external payable {
        subsidy.claim(id, payable(address(this)), amount, proof);
    }
}
