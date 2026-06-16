// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioNFT} from "../src/PortfolioNFT.sol";

/**
 * @title DeployPortfolioNFT
 * @notice PortfolioNFT 的部署脚本。
 *
 * @dev 用法(本地 anvil 演示):
 *   1. 另开一个终端:  anvil
 *   2. 部署(广播):
 *        forge script script/DeployPortfolioNFT.s.sol \
 *          --rpc-url http://127.0.0.1:8545 --broadcast \
 *          --private-key <anvil 第一个私钥>
 *
 *   真实测试网(如 Sepolia)请用环境变量传入,不要把私钥写进代码或命令历史:
 *        $env:PRIVATE_KEY = "0x..."         # PowerShell
 *        $env:RPC_URL     = "https://sepolia.infura.io/v3/<KEY>"
 *        forge.exe script script/DeployPortfolioNFT.s.sol \
 *          --rpc-url $env:RPC_URL --broadcast --private-key $env:PRIVATE_KEY
 *
 * @dev 可通过环境变量覆盖默认参数(都可选):
 *   NFT_NAME        集合名称       (默认 "Portfolio NFT")
 *   NFT_SYMBOL      集合符号       (默认 "PNFT")
 *   NFT_OWNER       初始 owner     (默认 = 部署者地址)
 *   NFT_MAX_SUPPLY  最大供应量     (默认 10000)
 *   NFT_PRICE_WEI   公开铸造单价   (默认 0.01 ether)
 *   NFT_BASE_URI    初始 baseURI   (默认 ""，部署后再 setBaseURI 揭示)
 */
contract DeployPortfolioNFT is Script {
    function run() external returns (PortfolioNFT nft) {
        // ---- 读取可选环境变量,提供合理默认值 ----
        string memory name_ = vm.envOr("NFT_NAME", string("Portfolio NFT"));
        string memory symbol_ = vm.envOr("NFT_SYMBOL", string("PNFT"));
        uint256 maxSupply_ = vm.envOr("NFT_MAX_SUPPLY", uint256(10_000));
        uint256 price_ = vm.envOr("NFT_PRICE_WEI", uint256(0.01 ether));
        string memory baseURI_ = vm.envOr("NFT_BASE_URI", string(""));

        // 部署者地址:有 PRIVATE_KEY 环境变量则用它推导,否则用 forge 默认 sender
        address deployer;
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            deployer = vm.addr(pk);
        } else {
            deployer = msg.sender;
        }
        address owner_ = vm.envOr("NFT_OWNER", deployer);

        // ---- 广播交易 ----
        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast();
        }

        nft = new PortfolioNFT(name_, symbol_, owner_, maxSupply_, price_, baseURI_);

        vm.stopBroadcast();

        // ---- 打印部署信息 ----
        console.log("PortfolioNFT deployed at:", address(nft));
        console.log("  name       :", name_);
        console.log("  symbol     :", symbol_);
        console.log("  owner      :", owner_);
        console.log("  maxSupply  :", maxSupply_);
        console.log("  mintPrice  :", price_);
        console.log("  baseURI    :", baseURI_);
    }
}
