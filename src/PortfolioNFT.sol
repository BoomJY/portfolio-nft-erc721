// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PortfolioNFT
 * @author 作品集示例(solidity-15天 Day5 / 作品#1)
 * @notice 一个面向作品集 / 接单样板的 ERC-721 NFT 合约,基于 OpenZeppelin v5.1.0。
 *
 * @dev 设计要点(为什么这样写):
 *
 *  1. 铸造模式:本合约采用「公开 + 收费」铸造(publicMint),任何人支付 `mintPrice`
 *     即可铸造。这是 PFP / generative art 项目最常见的商业模式。同时保留 owner-only
 *     的 `ownerMint`,用于团队预留、空投、白名单合作等场景(不收费)。
 *     —— 若你的项目只需要 owner 铸造,可以删掉 publicMint 与 withdraw,把合约简化为
 *        纯白名单/预留模式;两种模式的取舍见 README。
 *
 *  2. tokenId 自增:OpenZeppelin v5 移除了 Counters 库,这里用一个普通 `uint256`
 *     计数器 `_nextTokenId`,从 0 开始递增。每次铸造取当前值作为 tokenId,然后 +1。
 *     这样 tokenId 连续、可预测,便于 metadata 与前端展示。
 *
 *  3. metadata / tokenURI:遵循 ERC-721 Metadata 扩展。`tokenURI(id)` = `baseURI + id`。
 *     baseURI 一般指向 IPFS 目录(如 `ipfs://<CID>/`),目录下每个 token 有一个
 *     `<id>.json`(本合约采用「不带扩展名」的拼接 `baseURI + id`,即 metadata 文件名
 *     就是 token 编号,无后缀;这是 OZ 默认拼接方式。若你的元数据带 .json 后缀,见
 *     README「带 .json 后缀」一节,需重写 tokenURI)。
 *     baseURI 由 owner 通过 `setBaseURI` 设置,支持「先盲盒占位、揭示后再换正式 CID」
 *     的 reveal 流程。
 *
 *  4. 安全:
 *     - publicMint 在转账(铸造)前先修改状态(checks-effects-interactions),并对
 *       `msg.value` 做精确校验,防止欠费/多付;
 *     - withdraw 仅 owner 可调用,使用 call 转账并检查返回值;
 *     - maxSupply 在部署时固定,铸造时校验,防止超发。
 */
contract PortfolioNFT is ERC721, Ownable {
    // ---------------------------------------------------------------------
    // 状态变量
    // ---------------------------------------------------------------------

    /// @notice 下一个将被铸造的 tokenId(同时也等于「已铸造数量」)。从 0 开始。
    uint256 private _nextTokenId;

    /// @notice 集合最大供应量,部署时固定,不可更改。
    uint256 public immutable maxSupply;

    /// @notice 公开铸造单价(wei)。可由 owner 调整。
    uint256 public mintPrice;

    /// @notice tokenURI 拼接所用的基础 URI(通常是 IPFS 目录,如 "ipfs://<CID>/")。
    string private _baseTokenURI;

    // ---------------------------------------------------------------------
    // 事件
    // ---------------------------------------------------------------------

    /// @notice 当 baseURI 被更新时触发(便于前端/索引器感知 reveal)。
    event BaseURIUpdated(string newBaseURI);

    /// @notice 当公开铸造价格被更新时触发。
    event MintPriceUpdated(uint256 newPrice);

    /// @notice 当合约余额被提取时触发。
    event Withdrawn(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // 自定义错误(比 require 字符串更省 gas,且便于前端解析)
    // ---------------------------------------------------------------------

    /// @notice 铸造会导致超过最大供应量。
    error MaxSupplyExceeded(uint256 requested, uint256 remaining);

    /// @notice 公开铸造时支付金额与价格不符。
    error IncorrectPayment(uint256 sent, uint256 required);

    /// @notice 提现时无可提余额。
    error NothingToWithdraw();

    /// @notice 提现转账失败。
    error WithdrawFailed();

    /// @notice 铸造目标地址为零地址。
    error MintToZeroAddress();

    // ---------------------------------------------------------------------
    // 构造函数
    // ---------------------------------------------------------------------

    /**
     * @param name_        集合名称(ERC721 name)
     * @param symbol_      集合符号(ERC721 symbol)
     * @param initialOwner 初始 owner(OZ v5 的 Ownable 必须显式传入,不能为零地址)
     * @param maxSupply_   最大供应量(>0)
     * @param mintPrice_   公开铸造单价(wei),可为 0(表示免费公开铸造)
     * @param baseURI_     初始 baseURI(可为空字符串,后续用 setBaseURI 设置)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address initialOwner,
        uint256 maxSupply_,
        uint256 mintPrice_,
        string memory baseURI_
    ) ERC721(name_, symbol_) Ownable(initialOwner) {
        require(maxSupply_ > 0, "maxSupply must be > 0");
        maxSupply = maxSupply_;
        mintPrice = mintPrice_;
        _baseTokenURI = baseURI_;
    }

    // ---------------------------------------------------------------------
    // 铸造
    // ---------------------------------------------------------------------

    /**
     * @notice 公开铸造:支付 `mintPrice` 给自己铸造 1 个 NFT。
     * @dev 使用 _safeMint,若 `to` 是合约则要求其实现 onERC721Received。
     *      遵循 checks-effects-interactions:先校验、改计数器,再调用 _safeMint。
     * @return tokenId 本次铸造得到的 tokenId
     */
    function publicMint() external payable returns (uint256 tokenId) {
        if (msg.value != mintPrice) {
            revert IncorrectPayment(msg.value, mintPrice);
        }
        tokenId = _mintNext(msg.sender);
    }

    /**
     * @notice Owner 铸造(免费),用于团队预留 / 空投 / 白名单。
     * @param to 接收地址
     * @return tokenId 本次铸造得到的 tokenId
     */
    function ownerMint(address to) external onlyOwner returns (uint256 tokenId) {
        tokenId = _mintNext(to);
    }

    /**
     * @notice Owner 批量铸造给同一地址(空投常用)。
     * @param to       接收地址
     * @param quantity 数量(>0)
     */
    function ownerMintBatch(address to, uint256 quantity) external onlyOwner {
        require(quantity > 0, "quantity must be > 0");
        uint256 remaining = maxSupply - _nextTokenId;
        if (quantity > remaining) {
            revert MaxSupplyExceeded(quantity, remaining);
        }
        for (uint256 i = 0; i < quantity; i++) {
            _mintNext(to);
        }
    }

    /**
     * @dev 内部铸造核心:校验零地址与供应量上限,取当前 tokenId,计数器自增,_safeMint。
     */
    function _mintNext(address to) internal returns (uint256 tokenId) {
        if (to == address(0)) {
            revert MintToZeroAddress();
        }
        // 供应量校验:_nextTokenId 即已铸造数量
        if (_nextTokenId >= maxSupply) {
            revert MaxSupplyExceeded(1, 0);
        }
        tokenId = _nextTokenId;
        _nextTokenId = tokenId + 1;
        _safeMint(to, tokenId);
    }

    // ---------------------------------------------------------------------
    // 元数据 / tokenURI
    // ---------------------------------------------------------------------

    /**
     * @dev 覆盖 OZ 的 _baseURI(),返回我们存储的 baseURI。
     *      ERC721.tokenURI(id) 会用 `_baseURI() + id.toString()` 拼接。
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @notice Owner 设置 / 更新 baseURI(支持盲盒 reveal)。
     * @param newBaseURI 新的基础 URI,通常以 "/" 结尾,如 "ipfs://<CID>/"
     */
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    /// @notice 读取当前 baseURI(测试 / 前端方便用)。
    function baseURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    // 说明:tokenURI(uint256) 直接复用 OZ ERC721 的实现:
    //   - 若 token 不存在 → revert ERC721NonexistentToken(tokenId)
    //   - 若 baseURI 为空 → 返回空字符串 ""
    //   - 否则返回 baseURI + tokenId
    // 因此无需在此覆盖。

    // ---------------------------------------------------------------------
    // 供应量 / 价格 / 资金管理
    // ---------------------------------------------------------------------

    /// @notice 当前已铸造总量。
    function totalMinted() external view returns (uint256) {
        return _nextTokenId;
    }

    /// @notice 剩余可铸造数量。
    function remainingSupply() external view returns (uint256) {
        return maxSupply - _nextTokenId;
    }

    /// @notice Owner 调整公开铸造价格。
    function setMintPrice(uint256 newPrice) external onlyOwner {
        mintPrice = newPrice;
        emit MintPriceUpdated(newPrice);
    }

    /**
     * @notice Owner 提取合约内的全部 ETH(来自 publicMint 的收入)。
     * @param to 收款地址
     */
    function withdraw(address payable to) external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert NothingToWithdraw();
        }
        (bool ok, ) = to.call{value: balance}("");
        if (!ok) {
            revert WithdrawFailed();
        }
        emit Withdrawn(to, balance);
    }

    // supportsInterface 由 ERC721 实现(ERC165),已覆盖 IERC721 / IERC721Metadata / IERC165。
    // 这里不需要重写,除非加入更多扩展接口。
}
