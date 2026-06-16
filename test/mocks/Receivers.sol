// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title ERC721ReceiverMock
 * @dev 一个正确实现 IERC721Receiver 的合约,onERC721Received 返回正确 selector,
 *      因此可以作为 safeTransferFrom / _safeMint 的合法接收方。
 *      同时记录最后一次回调的参数,便于断言。
 */
contract ERC721ReceiverMock is IERC721Receiver {
    address public lastOperator;
    address public lastFrom;
    uint256 public lastTokenId;
    bytes public lastData;
    bool public received;

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        lastOperator = operator;
        lastFrom = from;
        lastTokenId = tokenId;
        lastData = data;
        received = true;
        return IERC721Receiver.onERC721Received.selector;
    }
}

/**
 * @title NonReceiver
 * @dev 一个普通合约,没有实现 onERC721Received。
 *      用它作为 safeTransfer 的目标,应当导致 revert
 *      (ERC721InvalidReceiver),用于验证 safe 系列的保护。
 */
contract NonReceiver {
// 故意留空:不实现 IERC721Receiver
}

/**
 * @title RejectingReceiver
 * @dev 实现了 onERC721Received,但返回错误的 selector,
 *      用于验证「返回值不匹配也会被拒绝」。
 */
contract RejectingReceiver is IERC721Receiver {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return 0xdeadbeef; // 错误的 selector
    }
}

/**
 * @title RejectingPayable
 * @dev 一个拒收 ETH 的合约(receive 直接 revert),
 *      用于验证 withdraw 在转账失败时会 revert WithdrawFailed。
 */
contract RejectingPayable {
    receive() external payable {
        revert("I reject ETH");
    }
}
