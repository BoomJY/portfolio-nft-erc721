// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PortfolioNFT} from "../src/PortfolioNFT.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ERC721ReceiverMock,
    NonReceiver,
    RejectingReceiver,
    RejectingPayable
} from "./mocks/Receivers.sol";

/**
 * @title PortfolioNFTTest
 * @notice PortfolioNFT 的完整单元测试。覆盖:
 *  - mint 权限(publicMint 收费 / ownerMint 仅 owner)
 *  - tokenId 自增
 *  - 不存在 / 越界 tokenURI revert
 *  - ownerOf 正确
 *  - tokenURI 拼接正确(含 reveal)
 *  - safeTransfer 到合约需 onERC721Received(正确接收 / 不实现 / 错误返回值)
 *  - supportsInterface(ERC165)
 *  - 供应量上限、价格、提现、批量铸造、事件
 */
contract PortfolioNFTTest is Test {
    PortfolioNFT internal nft;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    string internal constant NAME = "Portfolio NFT";
    string internal constant SYMBOL = "PNFT";
    uint256 internal constant MAX_SUPPLY = 5;
    uint256 internal constant PRICE = 0.01 ether;
    string internal constant BASE_URI = "ipfs://bafyExampleCID/";

    // 复制合约里的事件签名以便用 expectEmit 断言
    event BaseURIUpdated(string newBaseURI);
    event MintPriceUpdated(uint256 newPrice);
    event Withdrawn(address indexed to, uint256 amount);
    // ERC721 Transfer 事件(用于校验铸造发出的 Transfer)
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function setUp() public {
        vm.prank(owner);
        nft = new PortfolioNFT(NAME, SYMBOL, owner, MAX_SUPPLY, PRICE, BASE_URI);

        // 给测试账户一些 ETH 用于付费铸造
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ---------------------------------------------------------------------
    // 构造 / 元信息
    // ---------------------------------------------------------------------

    function test_Constructor_SetsMetadata() public view {
        assertEq(nft.name(), NAME);
        assertEq(nft.symbol(), SYMBOL);
        assertEq(nft.owner(), owner);
        assertEq(nft.maxSupply(), MAX_SUPPLY);
        assertEq(nft.mintPrice(), PRICE);
        assertEq(nft.baseURI(), BASE_URI);
        assertEq(nft.totalMinted(), 0);
        assertEq(nft.remainingSupply(), MAX_SUPPLY);
    }

    function test_Constructor_RevertsOnZeroMaxSupply() public {
        vm.expectRevert(bytes("maxSupply must be > 0"));
        new PortfolioNFT(NAME, SYMBOL, owner, 0, PRICE, BASE_URI);
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        // OZ v5 Ownable 不允许零地址 owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PortfolioNFT(NAME, SYMBOL, address(0), MAX_SUPPLY, PRICE, BASE_URI);
    }

    // ---------------------------------------------------------------------
    // publicMint:权限 / 收费 / tokenId 自增
    // ---------------------------------------------------------------------

    function test_PublicMint_Succeeds_WithExactPayment() public {
        vm.prank(alice);
        uint256 id = nft.publicMint{value: PRICE}();

        assertEq(id, 0);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.totalMinted(), 1);
        assertEq(address(nft).balance, PRICE);
    }

    function test_PublicMint_EmitsTransferFromZero() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, 0);
        vm.prank(alice);
        nft.publicMint{value: PRICE}();
    }

    function test_PublicMint_TokenIdIncrements() public {
        vm.prank(alice);
        uint256 id0 = nft.publicMint{value: PRICE}();
        vm.prank(bob);
        uint256 id1 = nft.publicMint{value: PRICE}();
        vm.prank(alice);
        uint256 id2 = nft.publicMint{value: PRICE}();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(2), alice);
        assertEq(nft.totalMinted(), 3);
        assertEq(nft.remainingSupply(), MAX_SUPPLY - 3);
    }

    function test_PublicMint_RevertsOnUnderpayment() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioNFT.IncorrectPayment.selector, PRICE - 1, PRICE)
        );
        nft.publicMint{value: PRICE - 1}();
    }

    function test_PublicMint_RevertsOnOverpayment() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioNFT.IncorrectPayment.selector, PRICE + 1, PRICE)
        );
        nft.publicMint{value: PRICE + 1}();
    }

    function test_PublicMint_RevertsWhenSoldOut() public {
        // 铸满 MAX_SUPPLY
        for (uint256 i = 0; i < MAX_SUPPLY; i++) {
            vm.prank(alice);
            nft.publicMint{value: PRICE}();
        }
        assertEq(nft.remainingSupply(), 0);

        // 再铸应当超供
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PortfolioNFT.MaxSupplyExceeded.selector, 1, 0));
        nft.publicMint{value: PRICE}();
    }

    function test_PublicMint_FreeWhenPriceZero() public {
        // 部署一个 0 价合约
        vm.prank(owner);
        PortfolioNFT free = new PortfolioNFT(NAME, SYMBOL, owner, 3, 0, BASE_URI);

        vm.prank(alice);
        uint256 id = free.publicMint{value: 0}();
        assertEq(id, 0);
        assertEq(free.ownerOf(0), alice);
    }

    // ---------------------------------------------------------------------
    // ownerMint / 批量:权限
    // ---------------------------------------------------------------------

    function test_OwnerMint_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.ownerMint(alice);
    }

    function test_OwnerMint_Succeeds() public {
        vm.prank(owner);
        uint256 id = nft.ownerMint(bob);
        assertEq(id, 0);
        assertEq(nft.ownerOf(0), bob);
        assertEq(nft.totalMinted(), 1);
    }

    function test_OwnerMintBatch_Succeeds() public {
        vm.prank(owner);
        nft.ownerMintBatch(alice, 3);
        assertEq(nft.totalMinted(), 3);
        assertEq(nft.balanceOf(alice), 3);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
    }

    function test_OwnerMintBatch_OnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        nft.ownerMintBatch(bob, 2);
    }

    function test_OwnerMintBatch_RevertsWhenExceedsSupply() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioNFT.MaxSupplyExceeded.selector, MAX_SUPPLY + 1, MAX_SUPPLY)
        );
        nft.ownerMintBatch(alice, MAX_SUPPLY + 1);
    }

    function test_OwnerMintBatch_RevertsOnZeroQuantity() public {
        vm.prank(owner);
        vm.expectRevert(bytes("quantity must be > 0"));
        nft.ownerMintBatch(alice, 0);
    }

    function test_Mint_RevertsOnZeroAddress() public {
        vm.prank(owner);
        // _mintNext 显式拦截零地址(在 OZ 检查之前)
        vm.expectRevert(PortfolioNFT.MintToZeroAddress.selector);
        nft.ownerMint(address(0));
    }

    // ---------------------------------------------------------------------
    // ownerOf:不存在的 token revert
    // ---------------------------------------------------------------------

    function test_OwnerOf_RevertsForNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        nft.ownerOf(999);
    }

    // ---------------------------------------------------------------------
    // tokenURI:拼接 / 不存在 revert / reveal
    // ---------------------------------------------------------------------

    function test_TokenURI_ConcatenatesBaseURIAndId() public {
        vm.prank(alice);
        nft.publicMint{value: PRICE}(); // id 0
        vm.prank(alice);
        nft.publicMint{value: PRICE}(); // id 1

        assertEq(nft.tokenURI(0), string.concat(BASE_URI, "0"));
        assertEq(nft.tokenURI(1), string.concat(BASE_URI, "1"));
    }

    function test_TokenURI_RevertsForNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        nft.tokenURI(0);
    }

    function test_TokenURI_RevertsForOutOfRange() public {
        // 铸 1 个,然后查一个越界的 tokenId
        vm.prank(alice);
        nft.publicMint{value: PRICE}();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        nft.tokenURI(42);
    }

    function test_TokenURI_EmptyWhenNoBaseURI() public {
        vm.prank(owner);
        PortfolioNFT noBase = new PortfolioNFT(NAME, SYMBOL, owner, 3, 0, "");
        vm.prank(alice);
        noBase.publicMint{value: 0}();
        // baseURI 为空时,OZ 返回空字符串
        assertEq(noBase.tokenURI(0), "");
    }

    function test_SetBaseURI_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setBaseURI("ipfs://newCID/");
    }

    function test_SetBaseURI_RevealFlow() public {
        vm.prank(alice);
        nft.publicMint{value: PRICE}(); // id 0
        assertEq(nft.tokenURI(0), string.concat(BASE_URI, "0"));

        string memory revealed = "ipfs://bafyRevealedCID/";
        vm.expectEmit(false, false, false, true);
        emit BaseURIUpdated(revealed);
        vm.prank(owner);
        nft.setBaseURI(revealed);

        assertEq(nft.baseURI(), revealed);
        assertEq(nft.tokenURI(0), string.concat(revealed, "0"));
    }

    // ---------------------------------------------------------------------
    // safeTransfer 到合约:需 onERC721Received
    // ---------------------------------------------------------------------

    function test_SafeMint_ToValidReceiverContract() public {
        ERC721ReceiverMock receiver = new ERC721ReceiverMock();
        vm.prank(owner);
        nft.ownerMint(address(receiver)); // ownerMint 用 _safeMint

        assertEq(nft.ownerOf(0), address(receiver));
        assertTrue(receiver.received());
        assertEq(receiver.lastFrom(), address(0)); // 铸造 from = 0
        assertEq(receiver.lastTokenId(), 0);
    }

    function test_SafeMint_RevertsToNonReceiverContract() public {
        NonReceiver bad = new NonReceiver();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(bad))
        );
        nft.ownerMint(address(bad));
    }

    function test_SafeTransferFrom_ToValidReceiverContract() public {
        // alice 先铸一个,再 safeTransfer 给接收合约
        vm.prank(alice);
        nft.publicMint{value: PRICE}(); // id 0, owner = alice

        ERC721ReceiverMock receiver = new ERC721ReceiverMock();
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(receiver), 0);

        assertEq(nft.ownerOf(0), address(receiver));
        assertTrue(receiver.received());
        assertEq(receiver.lastOperator(), alice);
        assertEq(receiver.lastFrom(), alice);
        assertEq(receiver.lastTokenId(), 0);
    }

    function test_SafeTransferFrom_RevertsToNonReceiver() public {
        vm.prank(alice);
        nft.publicMint{value: PRICE}(); // id 0

        NonReceiver bad = new NonReceiver();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(bad))
        );
        nft.safeTransferFrom(alice, address(bad), 0);
    }

    function test_SafeTransferFrom_RevertsToRejectingReceiver() public {
        vm.prank(alice);
        nft.publicMint{value: PRICE}(); // id 0

        RejectingReceiver bad = new RejectingReceiver();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(bad))
        );
        nft.safeTransferFrom(alice, address(bad), 0);
    }

    function test_TransferFrom_ToNonReceiverContract_Succeeds() public {
        // 非 safe 的 transferFrom 不检查 onERC721Received,因此可以转给普通合约
        vm.prank(alice);
        nft.publicMint{value: PRICE}(); // id 0

        NonReceiver plain = new NonReceiver();
        vm.prank(alice);
        nft.transferFrom(alice, address(plain), 0);
        assertEq(nft.ownerOf(0), address(plain));
    }

    // ---------------------------------------------------------------------
    // supportsInterface (ERC165)
    // ---------------------------------------------------------------------

    function test_SupportsInterface() public view {
        // ERC165 自身
        assertTrue(nft.supportsInterface(type(IERC165).interfaceId));
        // ERC721
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId));
        // ERC721Metadata
        assertTrue(nft.supportsInterface(type(IERC721Metadata).interfaceId));
        // 一个随机/无效接口应返回 false
        assertFalse(nft.supportsInterface(0xffffffff));
        assertFalse(nft.supportsInterface(0x12345678));
    }

    // ---------------------------------------------------------------------
    // 价格调整 / 提现
    // ---------------------------------------------------------------------

    function test_SetMintPrice_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setMintPrice(1 ether);
    }

    function test_SetMintPrice_UpdatesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit MintPriceUpdated(0.05 ether);
        vm.prank(owner);
        nft.setMintPrice(0.05 ether);
        assertEq(nft.mintPrice(), 0.05 ether);

        // 新价格生效
        vm.prank(alice);
        nft.publicMint{value: 0.05 ether}();
        assertEq(nft.ownerOf(0), alice);
    }

    function test_Withdraw_OnlyOwner() public {
        vm.prank(alice);
        nft.publicMint{value: PRICE}();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.withdraw(payable(alice));
    }

    function test_Withdraw_TransfersBalanceAndEmits() public {
        // 两次付费铸造,合约累计 2*PRICE
        vm.prank(alice);
        nft.publicMint{value: PRICE}();
        vm.prank(bob);
        nft.publicMint{value: PRICE}();
        assertEq(address(nft).balance, 2 * PRICE);

        address payable recipient = payable(makeAddr("recipient"));
        uint256 before = recipient.balance;

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(recipient, 2 * PRICE);
        vm.prank(owner);
        nft.withdraw(recipient);

        assertEq(address(nft).balance, 0);
        assertEq(recipient.balance, before + 2 * PRICE);
    }

    function test_Withdraw_RevertsWhenEmpty() public {
        vm.prank(owner);
        vm.expectRevert(PortfolioNFT.NothingToWithdraw.selector);
        nft.withdraw(payable(owner));
    }

    function test_Withdraw_RevertsWhenRecipientRejects() public {
        vm.prank(alice);
        nft.publicMint{value: PRICE}();

        RejectingPayable bad = new RejectingPayable();
        vm.prank(owner);
        vm.expectRevert(PortfolioNFT.WithdrawFailed.selector);
        nft.withdraw(payable(address(bad)));
    }

    // ---------------------------------------------------------------------
    // 模糊测试:tokenId 自增在任意数量铸造下保持连续
    // ---------------------------------------------------------------------

    function testFuzz_SequentialTokenIds(uint8 count) public {
        uint256 n = bound(count, 1, MAX_SUPPLY);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(alice);
            uint256 id = nft.publicMint{value: PRICE}();
            assertEq(id, i);
            assertEq(nft.ownerOf(i), alice);
        }
        assertEq(nft.totalMinted(), n);
    }
}
