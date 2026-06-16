# PortfolioNFT — ERC-721 NFT 合约(OpenZeppelin v5)

> **作品集编号**:作品 #1
> **对应计划**:`solidity-15天` 计划 **Day 5**(ERC-721 / NFT)
> **技术栈**:Solidity ^0.8.20 · Foundry · OpenZeppelin Contracts **v5.1.0**
> **状态**:`forge test` 全绿(38 passed,含 256 次 fuzz)

一个面向**作品集展示**与**接单交付**的 ERC-721 NFT 合约模板。代码完整、注释详尽(中文)、测试覆盖核心路径与边界情况,可直接作为真实 NFT 项目(PFP / 生成艺术 / 会员卡)的起点。

---

## 1. 这是什么

`PortfolioNFT` 继承自 OpenZeppelin 的 `ERC721` + `Ownable`,实现了一个**可收费公开铸造**的 NFT 集合,并提供 owner 专用的预留/空投铸造。核心能力:

| 能力 | 说明 |
| --- | --- |
| 公开收费铸造 `publicMint()` | 任何人支付 `mintPrice` 铸造 1 个,精确校验付款金额 |
| Owner 铸造 `ownerMint(to)` | 仅 owner,免费,用于团队预留 / 白名单合作 |
| Owner 批量铸造 `ownerMintBatch(to, n)` | 仅 owner,空投常用 |
| tokenId 自增 | OZ v5 已移除 `Counters`,本合约用普通 `uint256` 计数器,从 0 连续递增 |
| 最大供应量 `maxSupply` | 部署时固定(`immutable`),铸造时校验,杜绝超发 |
| baseURI / tokenURI | 指向 IPFS,支持「盲盒占位 → reveal 揭示」流程 |
| 资金管理 `withdraw(to)` | 仅 owner,提取铸造收入,`call` 转账并检查返回值 |
| ERC165 `supportsInterface` | 继承自 OZ,正确声明 IERC721 / IERC721Metadata / IERC165 |

源码:[`src/PortfolioNFT.sol`](src/PortfolioNFT.sol)

---

## 2. 设计要点(为什么这样写)

### 2.1 铸造模式:公开+收费 vs owner-only

本合约**默认采用「公开 + 收费」**(`publicMint`),因为这是 PFP / 生成艺术项目最主流的商业模式;同时保留**免费的 owner 铸造**用于预留与空投。

- 如果你的项目**只需要白名单 / 预留**(例如内部会员卡、定向空投),可以删掉 `publicMint` 与 `withdraw`、`mintPrice`、`setMintPrice`,把合约收敛成纯 owner-only 铸造,更简单也更省 gas。
- 如果你需要**白名单阶段 + 公售阶段**,可在 `publicMint` 上叠加 Merkle proof 校验 + 阶段开关(本模板未内置,属于进阶扩展点)。

### 2.2 tokenId 自增(OZ v5 无 Counters)

OpenZeppelin v5 移除了 `Counters` 库。本合约用一个 `uint256 private _nextTokenId`,从 **0** 开始:每次铸造取当前值作为 tokenId,再 `+1`。好处是 tokenId **连续、可预测**,与 IPFS 上 `0 / 1 / …` 一一对应。`_nextTokenId` 同时等于「已铸造数量」,所以 `totalMinted()` / `remainingSupply()` 都 O(1)。

### 2.3 metadata / tokenURI 拼接

遵循 ERC-721 Metadata 扩展。OZ 的 `tokenURI(id)` 实现是:

```
tokenURI(id) = bytes(baseURI).length > 0 ? string.concat(baseURI, id.toString()) : ""
```

即 **`baseURI` + `tokenId`(十进制,无后缀)**。所以:

- `baseURI = "ipfs://<CID>/"`,`tokenId = 0` → `tokenURI(0) = "ipfs://<CID>/0"`
- 链下你需要在 IPFS 目录里放与编号同名的 JSON 文件(**文件名就是数字,无扩展名**):`<CID>/0`、`<CID>/1` …

> **如果你的元数据文件带 `.json` 后缀**(很多团队习惯 `0.json`),需要在合约里**覆盖 `tokenURI`**,在末尾拼接 `".json"`,例如:
> ```solidity
> function tokenURI(uint256 tokenId) public view override returns (string memory) {
>     _requireOwned(tokenId);
>     string memory base = _baseURI();
>     return bytes(base).length > 0
>         ? string.concat(base, Strings.toString(tokenId), ".json")
>         : "";
> }
> ```
> 本模板沿用 OZ 默认(无后缀)以保持最小惊讶;请按你的实际 IPFS 文件命名二选一。`metadata/0.json` 仅作为元数据**字段结构**示例(文件名带后缀只是方便本地查看)。

### 2.4 安全考量

- **Checks-Effects-Interactions**:`_mintNext` 先校验零地址 / 供应量、再自增计数器、最后才 `_safeMint`(外部交互)。
- **付款精确校验**:`publicMint` 要求 `msg.value == mintPrice`(不接受多付,避免用户误付且无退款逻辑);若你想「多付自动退零头」,可改成 `>=` 并退还差额。
- **提现**:`withdraw` 用 `call` 转账并检查返回值,失败 revert(`WithdrawFailed`);仅 owner 可调用。
- **超发防护**:`maxSupply` 为 `immutable`,任何铸造路径都过 `_mintNext` 的上限校验。
- **自定义错误**:用 `error` 而非 `require(string)`,更省 gas 且前端易解析。

### 2.5 OpenZeppelin v5 适配注意

本合约严格按 OZ **v5** API 编写(与 v4 有破坏性差异):

- `Ownable` 构造函数**必须**显式传 `initialOwner`(不能是零地址,否则 `OwnableInvalidOwner`)。
- 已**无** `Counters` —— 自己用 `uint256` 计数。
- 已**无** `_beforeTokenTransfer` —— 钩子统一为 `_update`(本合约未用到)。
- 存在性判断用 `_ownerOf` / `_requireOwned`;`tokenURI` 对不存在的 token 自动 `revert ERC721NonexistentToken`。
- 权限错误为 `OwnableUnauthorizedAccount(account)`。

---

## 3. 项目结构

```
03-foundry-erc721-nft/
├── src/
│   └── PortfolioNFT.sol            # 主合约
├── test/
│   ├── PortfolioNFT.t.sol          # 38 个测试(单元 + fuzz)
│   └── mocks/
│       └── Receivers.sol           # 测试用接收方:正确/不实现/错误返回/拒收ETH
├── script/
│   └── DeployPortfolioNFT.s.sol    # 部署脚本(支持环境变量参数化)
├── metadata/
│   └── 0.json                      # 示例元数据(OpenSea metadata standard)
├── lib/
│   ├── forge-std/                  # Foundry 标准库
│   └── openzeppelin-contracts/     # OZ v5.1.0(直接 clone,非 submodule)
├── remappings.txt                  # import 重映射
├── foundry.toml
└── README.md
```

---

## 4. 环境要求

- **Foundry**(forge / cast / anvil)。本项目使用 forge `1.5.1`、Solc `0.8.33` 验证通过。
- 依赖已随仓库提供在 `lib/`(直接 clone,**不使用 git submodule**),clone 本仓库后可直接 build,无需额外 `forge install`。

> **Windows 提示**:若 `forge` 不在 PATH,请用绝对路径调用,例如
> `C:/Users/<你>/foundry/forge.exe`。另外**避免在含中文(CJK)的路径下 build**(会触发 `Error writing output JSON`),请放在纯 ASCII 路径的盘符下(如 `E:\...`)。

---

## 5. 如何 build / test / 运行

### 5.1 编译

```bash
forge build
```

### 5.2 测试(核心验证命令)

```bash
forge test
# 更详细输出:
forge test -vvv
# 查看 gas 报告:
forge test --gas-report
```

预期:**38 passed; 0 failed**。

### 5.3 本地部署演示(anvil)

```bash
# 终端 1:启动本地链
anvil

# 终端 2:广播部署(用 anvil 打印的第一个私钥)
forge script script/DeployPortfolioNFT.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

> 不带 `--rpc-url` 直接 `forge script script/DeployPortfolioNFT.s.sol` 会做一次**本地模拟**(dry-run),用于快速验证脚本逻辑而不上链。

### 5.4 部署到真实测试网(如 Sepolia)

```powershell
# PowerShell:用环境变量传敏感信息,切勿写进命令历史或代码
$env:PRIVATE_KEY = "0x<你的部署私钥>"
$env:RPC_URL     = "https://sepolia.infura.io/v3/<你的KEY>"

forge script script/DeployPortfolioNFT.s.sol `
  --rpc-url $env:RPC_URL `
  --broadcast `
  --private-key $env:PRIVATE_KEY
```

---

## 6. metadata JSON 结构与 IPFS

### 6.1 单个 token 的元数据(OpenSea metadata standard)

见 [`metadata/0.json`](metadata/0.json):

```json
{
  "name": "Portfolio NFT #0",
  "description": "……",
  "image": "ipfs://bafyExampleImageCID/0.png",
  "external_url": "https://example.com/nft/0",
  "attributes": [
    { "trait_type": "Background", "value": "Blue" },
    { "trait_type": "Rarity", "value": "Common" },
    { "trait_type": "Level", "value": 1, "display_type": "number" }
  ]
}
```

字段说明:`name` / `description` / `image`(指向 IPFS 图片)/ `external_url`(可选)/ `attributes`(特征数组,`display_type` 可选 `number` / `boost_percentage` / `date` 等)。

### 6.2 IPFS 上传与 baseURI 设置流程

1. **上传图片目录**到 IPFS(Pinata / NFT.Storage / web3.storage 等),得到图片目录 CID,把每个 JSON 里的 `image` 改成 `ipfs://<图片CID>/<编号>.png`。
2. **上传 metadata 目录**(里面是 `0`、`1`、…,**与 `tokenURI` 拼接规则一致,无后缀**;若你保留 `.json` 后缀,请按 §2.3 覆盖 `tokenURI`),得到 metadata 目录 CID。
3. **设置 baseURI**:owner 调用 `setBaseURI("ipfs://<metadataCID>/")`(注意**结尾要带 `/`**)。
4. 之后 `tokenURI(id)` 即返回 `ipfs://<metadataCID>/<id>`,各大市场(OpenSea 等)会据此抓取展示。

> **盲盒 / Reveal**:发售期先 `setBaseURI` 指向一个「盲盒占位」目录(所有 token 返回同一张神秘图),售罄后再 `setBaseURI` 指向正式 metadata 目录即可揭示。

---

## 7. 测试覆盖说明(38 项)

测试文件:[`test/PortfolioNFT.t.sol`](test/PortfolioNFT.t.sol)

- **mint 权限**:`publicMint` 收费正确 / 欠费 / 多付 revert;`ownerMint`、`ownerMintBatch` 仅 owner(非 owner → `OwnableUnauthorizedAccount`)。
- **tokenId 自增**:多次铸造 id 连续 0,1,2…;`totalMinted` / `remainingSupply` 正确;**fuzz 测试**任意数量下 id 仍连续(256 runs)。
- **tokenURI**:拼接 `baseURI + id` 正确;**不存在 / 越界** token → `ERC721NonexistentToken` revert;无 baseURI 时返回空串;reveal(换 baseURI)后 URI 更新。
- **ownerOf**:正常返回持有者;不存在 token → revert。
- **safeTransfer 到合约**:转给**正确实现** `onERC721Received` 的合约成功并记录回调参数;转给**未实现**的普通合约 → `ERC721InvalidReceiver`;转给**返回错误 selector** 的合约 → `ERC721InvalidReceiver`;非 safe 的 `transferFrom` 转给普通合约则允许(对照组)。`_safeMint` 同理(铸造给接收合约)。
- **supportsInterface (ERC165)**:`IERC165` / `IERC721` / `IERC721Metadata` 均为 true;无效接口(`0xffffffff` 等)为 false。
- **供应量上限**:售罄后再铸 → `MaxSupplyExceeded`;批量超供 revert;`maxSupply == 0` 构造 revert。
- **价格 / 提现**:`setMintPrice` 仅 owner 且生效;`withdraw` 仅 owner、转账成功并发事件、空余额 revert(`NothingToWithdraw`)、收款方拒收 → `WithdrawFailed`。
- **零地址**:`mint` 到 `address(0)` → `MintToZeroAddress`;owner 为零地址构造 → `OwnableInvalidOwner`。
- **事件**:`Transfer`(铸造 from 0)、`BaseURIUpdated`、`MintPriceUpdated`、`Withdrawn` 均断言。

---

## 8. 接真实数据 / 上线前,你(用户)需要填什么

> **物理条件清单** —— 下面这些是代码无法替你决定、必须你提供的外部输入:

1. **集合参数**(部署时,均可用环境变量传入,见 §5.4 与部署脚本头部注释):
   - 名称 `NFT_NAME`、符号 `NFT_SYMBOL`
   - 最大供应量 `NFT_MAX_SUPPLY`(如 10000)
   - 公开铸造单价 `NFT_PRICE_WEI`(wei;如 0.01 ETH = `10000000000000000`)
   - 初始 owner `NFT_OWNER`(默认 = 部署者;**建议用多签**而非 EOA)
2. **资产与元数据**:
   - 你的 NFT **图片 / 美术资源**
   - 上传 IPFS 后得到的 **图片目录 CID** 与 **metadata 目录 CID**
   - 上线后由 owner 调用 `setBaseURI("ipfs://<metadataCID>/")`
3. **部署凭证**(放环境变量,**切勿提交进仓库**):
   - `PRIVATE_KEY`:部署者私钥
   - `RPC_URL`:目标网络 RPC(Infura / Alchemy / 公共节点)
   - (可选)`ETHERSCAN_API_KEY`:用于 `--verify` 在 Etherscan 开源验证
4. **(可选)源码验证**:部署时加 `--verify --etherscan-api-key $env:ETHERSCAN_API_KEY` 可自动在区块浏览器验证合约。

> 安全提醒:`.env` / 私钥 / RPC KEY 已在 `.gitignore` 中忽略;**请勿**把私钥写进脚本、命令历史或公开仓库。生产环境的 owner 强烈建议改用 Gnosis Safe 多签。

---

## 9. 已知扩展点(本模板有意未做,留给真实项目)

- 白名单(Merkle proof)+ 分阶段开关(presale / public)
- 每地址铸造上限 `maxPerWallet`
- 版税(ERC-2981 `royaltyInfo`)
- 可暂停(`Pausable`)/ 元数据冻结(`freezeMetadata`)
- 多付自动退还零头

---

## 10. 许可证

MIT.
