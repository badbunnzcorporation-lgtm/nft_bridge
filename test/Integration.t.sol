// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contract/mocks/SimpleNFT.sol";
import "../contract/EthereumBridge.sol";
import "../contract/MegaEthBridge.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * Integration tests for full bridge flow
 * Tests the complete ETH ↔ MegaETH bridge with proper merkle proofs
 */
contract IntegrationTest is Test {
    SimpleNFT public ethNFT;
    SimpleNFT public megaEthNFT;
    EthereumBridge public ethBridge;
    MegaEthBridge public megaEthBridge;
    
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    uint256 constant TOKEN_ID = 1;
    uint256 constant MAX_SUPPLY = 3000;
    function _megaLocks(
        bytes32 lockHash,
        uint256 tokenId,
        address owner_,
        address recipient_,
        uint256 blockNumber
    ) internal pure returns (MegaEthBridge.LockData[] memory locks) {
        locks = new MegaEthBridge.LockData[](1);
        locks[0] = MegaEthBridge.LockData({
            tokenId: tokenId,
            owner: owner_,
            recipient: recipient_,
            blockNumber: blockNumber,
            lockHash: lockHash
        });
    }

    function _ethLocks(
        bytes32 lockHash,
        uint256 tokenId,
        address owner_,
        address recipient_,
        uint256 blockNumber
    ) internal pure returns (EthereumBridge.LockData[] memory locks) {
        locks = new EthereumBridge.LockData[](1);
        locks[0] = EthereumBridge.LockData({
            tokenId: tokenId,
            owner: owner_,
            recipient: recipient_,
            blockNumber: blockNumber,
            lockHash: lockHash
        });
    }

    function _bridgeToMega(
        address from,
        address to,
        uint256 tokenId
    ) internal {
        vm.roll(block.number + 1);
        vm.startPrank(from);
        ethNFT.approve(address(ethBridge), tokenId);
        uint256 lockBlock = block.number;
        ethBridge.lockNFT(tokenId, to);
        vm.stopPrank();

        bytes32 lockHash = keccak256(
            abi.encodePacked(tokenId, from, to, lockBlock, address(ethBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, to, lockHash, lockBlock));
        MegaEthBridge.LockData[] memory locks = _megaLocks(lockHash, tokenId, from, to, lockBlock);

        megaEthBridge.setBlockRoot(lockBlock, leaf, uint32(locks.length), locks);
        megaEthBridge.unlockNFTWithProof(
            tokenId,
            to,
            lockHash,
            lockBlock,
            new bytes32[](0)
        );
    }

    function _bridgeToEthereum(
        address from,
        address to,
        uint256 tokenId
    ) internal {
        vm.roll(block.number + 1);
        vm.startPrank(from);
        megaEthNFT.approve(address(megaEthBridge), tokenId);
        uint256 lockBlock = block.number;
        megaEthBridge.lockNFTForEthereum(tokenId, to);
        vm.stopPrank();

        bytes32 lockHash = keccak256(
            abi.encodePacked(tokenId, from, to, lockBlock, address(megaEthBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, to, lockHash, lockBlock));
        EthereumBridge.LockData[] memory locks = _ethLocks(lockHash, tokenId, from, to, lockBlock);

        ethBridge.setMegaEthBlockRoot(lockBlock, leaf, uint32(locks.length), locks);
        ethBridge.unlockNFTWithProof(
            tokenId,
            to,
            lockHash,
            lockBlock,
            new bytes32[](0)
        );
    }
    event NFTLocked(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed recipient,
        bytes32 lockHash,
        uint256 blockNumber
    );
    
    function setUp() public {
        // Deploy NFTs (using SimpleNFT for testing)
        ethNFT = new SimpleNFT(
            "Bad Bunnz ETH",
            "BBETH"
        );
        
        megaEthNFT = new SimpleNFT(
            "Bad Bunnz MegaETH",
            "BBMEGA"
        );
        
        // Deploy bridges
        ethBridge = new EthereumBridge(address(ethNFT));
        megaEthBridge = new MegaEthBridge(address(megaEthNFT));
        
        // Link bridges
        ethBridge.setMegaEthBridge(address(megaEthBridge));
        megaEthBridge.setEthereumBridge(address(ethBridge));
        
        // Set bridge addresses
        ethNFT.setBridgeAddress(address(ethBridge));
        megaEthNFT.setBridgeAddress(address(megaEthBridge));
        
        // Mint NFT to user1 on Ethereum
        address[] memory recipients = new address[](1);
        recipients[0] = user1;
        uint256[][] memory tokenIds = new uint256[][](1);
        tokenIds[0] = new uint256[](1);
        tokenIds[0][0] = TOKEN_ID;
        ethNFT.airdrop(recipients, tokenIds);
    }
    
    function test_FullBridgeFlow_ETH_To_MegaETH() public {
        // Step 1: User locks NFT on Ethereum
        vm.startPrank(user1);
        ethNFT.approve(address(ethBridge), TOKEN_ID);
        
        uint256 blockBefore = block.number;
        ethBridge.lockNFT(TOKEN_ID, user1);
        uint256 lockBlock = block.number;
        
        // Verify lock
        assertTrue(ethBridge.lockedTokens(TOKEN_ID));
        assertEq(ethNFT.ownerOf(TOKEN_ID), address(ethBridge));
        vm.stopPrank();
        
        // Step 2: Build merkle tree (single event)
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID, user1, user1, lockBlock, address(ethBridge))
        );
        
        bytes32 leaf = keccak256(
            abi.encodePacked(TOKEN_ID, user1, lockHash, lockBlock)
        );
        bytes32 root = leaf; // Single leaf, root = leaf
        bytes32[] memory proof = new bytes32[](0); // Empty proof for single leaf
        
        // Step 3: Set root on MegaETH
        MegaEthBridge.LockData[] memory locks = _megaLocks(lockHash, TOKEN_ID, user1, user1, lockBlock);
        megaEthBridge.setBlockRoot(lockBlock, root, uint32(locks.length), locks);
        assertEq(megaEthBridge.blockRoots(lockBlock), root);
        
        // Step 4: Unlock on MegaETH
        megaEthBridge.unlockNFTWithProof(
            TOKEN_ID,
            user1,
            lockHash,
            lockBlock,
            proof
        );
        
        // Verify NFT minted on MegaETH
        assertEq(megaEthNFT.ownerOf(TOKEN_ID), user1);
        assertTrue(megaEthBridge.activeOnMegaETH(TOKEN_ID));
    }
    
    function test_FullBridgeFlow_MegaETH_To_ETH() public {
        _bridgeToMega(user1, user1, TOKEN_ID);
        assertEq(megaEthNFT.ownerOf(TOKEN_ID), user1);
        
        vm.startPrank(user1);
        megaEthNFT.approve(address(megaEthBridge), TOKEN_ID);
        uint256 lockBlock = block.number;
        megaEthBridge.lockNFTForEthereum(TOKEN_ID, user1);
        vm.stopPrank();
        
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID, user1, user1, lockBlock, address(megaEthBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(TOKEN_ID, user1, lockHash, lockBlock));
        bytes32[] memory proof = new bytes32[](0);
        
        EthereumBridge.LockData[] memory locks = _ethLocks(lockHash, TOKEN_ID, user1, user1, lockBlock);
        ethBridge.setMegaEthBlockRoot(lockBlock, leaf, uint32(locks.length), locks);
        
        ethBridge.unlockNFTWithProof(
            TOKEN_ID,
            user1,
            lockHash,
            lockBlock,
            proof
        );
        
        assertEq(ethNFT.ownerOf(TOKEN_ID), user1);
        assertFalse(ethBridge.lockedTokens(TOKEN_ID));
    }
    
    function test_RoundTrip_Bridge() public {
        _bridgeToMega(user1, user1, TOKEN_ID);
        assertEq(megaEthNFT.ownerOf(TOKEN_ID), user1);
        
        _bridgeToEthereum(user1, user1, TOKEN_ID);
        assertEq(ethNFT.ownerOf(TOKEN_ID), user1);
        assertFalse(ethBridge.lockedTokens(TOKEN_ID));
        
        _bridgeToMega(user1, user1, TOKEN_ID);
        assertEq(megaEthNFT.ownerOf(TOKEN_ID), user1);
        assertTrue(megaEthBridge.activeOnMegaETH(TOKEN_ID));
        assertFalse(megaEthBridge.lockedTokens(TOKEN_ID));
    }
}

