// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contract/mocks/SimpleNFT.sol";
import "../contract/EthereumBridge.sol";
import "../contract/MegaEthBridge.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract BridgeTest is Test {
    SimpleNFT public ethNFT;
    SimpleNFT public megaEthNFT;
    EthereumBridge public ethBridge;
    MegaEthBridge public megaEthBridge;
    
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public owner = address(this);
    
    // Test data
    uint256 constant TOKEN_ID_1 = 1;
    uint256 constant TOKEN_ID_2 = 2;
    uint256 constant TOKEN_ID_3 = 3;
    uint256 constant MAX_SUPPLY = 3000;
    
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
        
        // Set bridge addresses on NFTs
        ethNFT.setBridgeAddress(address(ethBridge));
        megaEthNFT.setBridgeAddress(address(megaEthBridge));
        
        // Mint initial NFTs on Ethereum
        address[] memory recipients = new address[](3);
        recipients[0] = user1;
        recipients[1] = user1;
        recipients[2] = user2;
        
        uint256[][] memory tokenIds = new uint256[][](3);
        tokenIds[0] = new uint256[](1);
        tokenIds[0][0] = TOKEN_ID_1;
        tokenIds[1] = new uint256[](1);
        tokenIds[1][0] = TOKEN_ID_2;
        tokenIds[2] = new uint256[](1);
        tokenIds[2][0] = TOKEN_ID_3;
        
        ethNFT.airdrop(recipients, tokenIds);
        
        // Verify ownership
        assertEq(ethNFT.ownerOf(TOKEN_ID_1), user1);
        assertEq(ethNFT.ownerOf(TOKEN_ID_2), user1);
        assertEq(ethNFT.ownerOf(TOKEN_ID_3), user2);
    }
    
    function _megaLocks(
        bytes32 lockHash,
        uint256 tokenId,
        address lockOwner,
        address recipient,
        uint256 blockNumber
    ) internal pure returns (MegaEthBridge.LockData[] memory locks) {
        locks = new MegaEthBridge.LockData[](1);
        locks[0] = MegaEthBridge.LockData({
            tokenId: tokenId,
            owner: lockOwner,
            recipient: recipient,
            blockNumber: blockNumber,
            lockHash: lockHash
        });
    }
    
    function _ethLocks(
        bytes32 lockHash,
        uint256 tokenId,
        address lockOwner,
        address recipient,
        uint256 blockNumber
    ) internal pure returns (EthereumBridge.LockData[] memory locks) {
        locks = new EthereumBridge.LockData[](1);
        locks[0] = EthereumBridge.LockData({
            tokenId: tokenId,
            owner: lockOwner,
            recipient: recipient,
            blockNumber: blockNumber,
            lockHash: lockHash
        });
    }

    function _bridgeEthToMega(
        address from,
        address recipient,
        uint256 tokenId
    ) internal {
        vm.roll(block.number + 1);
        vm.startPrank(from);
        ethNFT.approve(address(ethBridge), tokenId);
        uint256 lockBlock = block.number;
        ethBridge.lockNFT(tokenId, recipient);
        vm.stopPrank();

        bytes32 lockHash = keccak256(
            abi.encodePacked(tokenId, from, recipient, lockBlock, address(ethBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, recipient, lockHash, lockBlock));
        MegaEthBridge.LockData[] memory locks = _megaLocks(lockHash, tokenId, from, recipient, lockBlock);

        megaEthBridge.setBlockRoot(lockBlock, leaf, uint32(locks.length), locks);
        megaEthBridge.unlockNFTWithProof(
            tokenId,
            recipient,
            lockHash,
            lockBlock,
            new bytes32[](0)
        );
    }

    function _bridgeMegaToEth(
        address from,
        address recipient,
        uint256 tokenId
    ) internal {
        vm.roll(block.number + 1);
        vm.startPrank(from);
        megaEthNFT.approve(address(megaEthBridge), tokenId);
        uint256 lockBlock = block.number;
        megaEthBridge.lockNFTForEthereum(tokenId, recipient);
        vm.stopPrank();

        bytes32 lockHash = keccak256(
            abi.encodePacked(tokenId, from, recipient, lockBlock, address(megaEthBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, recipient, lockHash, lockBlock));
        EthereumBridge.LockData[] memory locks = _ethLocks(lockHash, tokenId, from, recipient, lockBlock);

        ethBridge.setMegaEthBlockRoot(lockBlock, leaf, uint32(locks.length), locks);
        ethBridge.unlockNFTWithProof(
            tokenId,
            recipient,
            lockHash,
            lockBlock,
            new bytes32[](0)
        );
    }
    
    // ###################### Helper Functions ######################
    
    function buildMerkleTree(
        uint256[] memory tokenIds,
        address[] memory recipients,
        bytes32[] memory lockHashes,
        uint256 blockNumber
    ) internal pure returns (bytes32 root, bytes32[][] memory proofs) {
        require(
            tokenIds.length == recipients.length && 
            tokenIds.length == lockHashes.length,
            "Array length mismatch"
        );
        
        // Build leaves
        bytes32[] memory leaves = new bytes32[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(tokenIds[i], recipients[i], lockHashes[i], blockNumber)
            );
        }
        
        // Build merkle tree
        if (leaves.length == 1) {
            // Single leaf: root is the leaf itself
            root = leaves[0];
            proofs = new bytes32[][](1);
            proofs[0] = new bytes32[](0);
        } else if (leaves.length == 2) {
            // Two leaves: root is hash of both
            root = keccak256(abi.encodePacked(leaves[0], leaves[1]));
            proofs = new bytes32[][](2);
            proofs[0] = new bytes32[](1);
            proofs[0][0] = leaves[1];
            proofs[1] = new bytes32[](1);
            proofs[1][0] = leaves[0];
        } else {
            // Multiple leaves: build binary tree
            // For simplicity, we'll use a balanced tree approach
            // In production, use a proper merkle tree library
            bytes32[] memory currentLevel = leaves;
            uint256 levelSize = currentLevel.length;
            
            // Build tree bottom-up
            while (levelSize > 1) {
                uint256 nextLevelSize = (levelSize + 1) / 2;
                bytes32[] memory nextLevel = new bytes32[](nextLevelSize);
                
                for (uint256 i = 0; i < nextLevelSize; i++) {
                    uint256 leftIdx = i * 2;
                    uint256 rightIdx = leftIdx + 1;
                    
                    if (rightIdx < levelSize) {
                        nextLevel[i] = keccak256(abi.encodePacked(currentLevel[leftIdx], currentLevel[rightIdx]));
                    } else {
                        nextLevel[i] = currentLevel[leftIdx];
                    }
                }
                
                currentLevel = nextLevel;
                levelSize = nextLevelSize;
            }
            
            root = currentLevel[0];
            
            // Generate proofs (simplified - for full implementation use proper tree traversal)
            proofs = new bytes32[][](tokenIds.length);
            for (uint256 i = 0; i < tokenIds.length; i++) {
                // Simplified proof generation
                if (tokenIds.length == 1) {
                    proofs[i] = new bytes32[](0);
                } else {
                    proofs[i] = new bytes32[](1);
                    proofs[i][0] = i == 0 ? leaves[1] : leaves[0];
                }
            }
        }
    }
    
    // ###################### ETH → MegaETH Tests ######################
    
    function test_LockNFT_ETH_To_MegaETH() public {
        vm.startPrank(user1);
        
        // Approve bridge
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        
        // Lock NFT
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        
        // Verify NFT is locked
        assertTrue(ethBridge.lockedTokens(TOKEN_ID_1));
        assertEq(ethNFT.ownerOf(TOKEN_ID_1), address(ethBridge));
        
        vm.stopPrank();
    }
    
    function test_UnlockNFT_ETH_To_MegaETH_WithProof() public {
        vm.startPrank(user1);
        
        // Lock NFT
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        
        // Get lock data
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, user1, user1, block.number, address(ethBridge))
        );
        uint256 lockBlock = block.number;
        
        vm.stopPrank();
        
        // Build merkle tree and set root
        uint256[] memory tokenIds = new uint256[](1);
        address[] memory recipients = new address[](1);
        bytes32[] memory lockHashes = new bytes32[](1);
        
        tokenIds[0] = TOKEN_ID_1;
        recipients[0] = user1;
        lockHashes[0] = lockHash;
        
        (bytes32 root, bytes32[][] memory proofs) = buildMerkleTree(
            tokenIds,
            recipients,
            lockHashes,
            lockBlock
        );
        
        // Set root on MegaETH
        MegaEthBridge.LockData[] memory locks = _megaLocks(lockHash, TOKEN_ID_1, user1, user1, lockBlock);
        megaEthBridge.setBlockRoot(lockBlock, root, uint32(locks.length), locks);
        
        // Unlock on MegaETH
        megaEthBridge.unlockNFTWithProof(
            TOKEN_ID_1,
            user1,
            lockHash,
            lockBlock,
            proofs[0]
        );
        
        // Verify NFT minted on MegaETH
        assertEq(megaEthNFT.ownerOf(TOKEN_ID_1), user1);
        assertTrue(megaEthBridge.activeOnMegaETH(TOKEN_ID_1));
    }
    
    function test_BatchLock_ETH_To_MegaETH() public {
        vm.startPrank(user1);
        
        // Approve both tokens
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethNFT.approve(address(ethBridge), TOKEN_ID_2);
        
        // Batch lock
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_1;
        tokenIds[1] = TOKEN_ID_2;
        
        ethBridge.batchLockNFT(tokenIds, user1);
        
        // Verify both locked
        assertTrue(ethBridge.lockedTokens(TOKEN_ID_1));
        assertTrue(ethBridge.lockedTokens(TOKEN_ID_2));
        
        vm.stopPrank();
    }
    
    function test_Revert_DoubleLock() public {
        vm.startPrank(user1);
        
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        
        // Try to lock again
        vm.expectRevert("Token already locked");
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        
        vm.stopPrank();
    }
    
    function test_Revert_InvalidProof() public {
        vm.startPrank(user1);
        
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, user1, user1, block.number, address(ethBridge))
        );
        uint256 lockBlock = block.number;
        
        vm.stopPrank();
        
        // Set root
        MegaEthBridge.LockData[] memory locks = _megaLocks(lockHash, TOKEN_ID_1, user1, user1, lockBlock);
        megaEthBridge.setBlockRoot(lockBlock, bytes32(uint256(123)), uint32(locks.length), locks);
        
        // Try to unlock with invalid proof
        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = bytes32(uint256(456));
        
        vm.expectRevert("Invalid merkle proof");
        megaEthBridge.unlockNFTWithProof(
            TOKEN_ID_1,
            user1,
            lockHash,
            lockBlock,
            invalidProof
        );
    }
    
    // ###################### MegaETH → ETH Tests ######################
    
    function test_LockNFT_MegaETH_To_ETH() public {
        // First bridge to MegaETH using full flow
        _bridgeEthToMega(user1, user1, TOKEN_ID_1);
        
        // Now lock on MegaETH to bridge back
        vm.startPrank(user1);
        megaEthNFT.approve(address(megaEthBridge), TOKEN_ID_1);
        megaEthBridge.lockNFTForEthereum(TOKEN_ID_1, user1);
        
        // Verify locked
        assertTrue(megaEthBridge.lockedTokens(TOKEN_ID_1));
        assertEq(megaEthNFT.ownerOf(TOKEN_ID_1), address(megaEthBridge));
        
        vm.stopPrank();
    }
    
    function test_UnlockNFT_MegaETH_To_ETH_WithProof() public {
        // Bridge NFT to MegaETH first
        _bridgeEthToMega(user1, user1, TOKEN_ID_1);
        
        // Lock on MegaETH to bridge back
        vm.startPrank(user1);
        megaEthNFT.approve(address(megaEthBridge), TOKEN_ID_1);
        megaEthBridge.lockNFTForEthereum(TOKEN_ID_1, user1);
        
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, user1, user1, block.number, address(megaEthBridge))
        );
        uint256 lockBlock = block.number;
        
        vm.stopPrank();
        
        // Build merkle tree
        uint256[] memory tokenIds = new uint256[](1);
        address[] memory recipients = new address[](1);
        bytes32[] memory lockHashes = new bytes32[](1);
        
        tokenIds[0] = TOKEN_ID_1;
        recipients[0] = user1;
        lockHashes[0] = lockHash;
        
        (bytes32 root, bytes32[][] memory proofs) = buildMerkleTree(
            tokenIds,
            recipients,
            lockHashes,
            lockBlock
        );
        
        // Set root on Ethereum
        EthereumBridge.LockData[] memory locks = _ethLocks(lockHash, TOKEN_ID_1, user1, user1, lockBlock);
        ethBridge.setMegaEthBlockRoot(lockBlock, root, uint32(locks.length), locks);
        
        // Unlock on Ethereum (token was already locked from initial bridge)
        ethBridge.unlockNFTWithProof(
            TOKEN_ID_1,
            user1,
            lockHash,
            lockBlock,
            proofs[0]
        );
        
        // Verify NFT unlocked on Ethereum
        assertEq(ethNFT.ownerOf(TOKEN_ID_1), user1);
        assertFalse(ethBridge.lockedTokens(TOKEN_ID_1));
    }
    
    function test_Revert_SetBlockRootFromUnauthorized() public {
        vm.startPrank(user1);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        vm.stopPrank();
        
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, user1, user1, block.number, address(ethBridge))
        );
        MegaEthBridge.LockData[] memory locks = _megaLocks(lockHash, TOKEN_ID_1, user1, user1, block.number);
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(BridgeUnauthorized.selector, user2));
        megaEthBridge.setBlockRoot(block.number, lockHash, uint32(locks.length), locks);
    }
    
    function test_CanClearBlockRootBeforeUse() public {
        vm.startPrank(user1);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        vm.stopPrank();
        
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, user1, user1, block.number, address(ethBridge))
        );
        uint256 lockBlock = block.number;
        bytes32 root = keccak256(abi.encodePacked(TOKEN_ID_1, user1, lockHash, lockBlock));
        MegaEthBridge.LockData[] memory locks = _megaLocks(lockHash, TOKEN_ID_1, user1, user1, lockBlock);
        
        megaEthBridge.setBlockRoot(lockBlock, root, uint32(locks.length), locks);
        megaEthBridge.clearBlockRoot(lockBlock);
        megaEthBridge.setBlockRoot(lockBlock, root, uint32(locks.length), locks);
    }
    
    function test_ClearBlockRootAfterUseFails() public {
        vm.startPrank(user1);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        uint256 lockBlock = block.number;
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        vm.stopPrank();
        
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, user1, user1, lockBlock, address(ethBridge))
        );
        bytes32 root = keccak256(abi.encodePacked(TOKEN_ID_1, user1, lockHash, lockBlock));
        bytes32[] memory proof = new bytes32[](0);
        MegaEthBridge.LockData[] memory locks = _megaLocks(lockHash, TOKEN_ID_1, user1, user1, lockBlock);
        
        megaEthBridge.setBlockRoot(lockBlock, root, uint32(locks.length), locks);
        megaEthBridge.unlockNFTWithProof(TOKEN_ID_1, user1, lockHash, lockBlock, proof);
        
        vm.expectRevert(abi.encodeWithSelector(BridgeInvalidOperation.selector, "Root already used"));
        megaEthBridge.clearBlockRoot(lockBlock);
    }
    
    function test_BatchLock_MegaETH_To_ETH() public {
        // Setup: Bridge NFTs to MegaETH so they are active
        _bridgeEthToMega(user1, user1, TOKEN_ID_1);
        _bridgeEthToMega(user1, user1, TOKEN_ID_2);
        
        vm.startPrank(user1);
        megaEthNFT.approve(address(megaEthBridge), TOKEN_ID_1);
        megaEthNFT.approve(address(megaEthBridge), TOKEN_ID_2);
        
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_1;
        tokenIds[1] = TOKEN_ID_2;
        
        megaEthBridge.batchLockNFTForEthereum(tokenIds, user1);
        
        assertTrue(megaEthBridge.lockedTokens(TOKEN_ID_1));
        assertTrue(megaEthBridge.lockedTokens(TOKEN_ID_2));
        
        vm.stopPrank();
    }
    
    // ###################### Edge Cases ######################
    
    function test_Revert_LockWithoutApproval() public {
        vm.startPrank(user1);
        
        vm.expectRevert();
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        
        vm.stopPrank();
    }
    
    function test_Revert_UnlockWithoutRoot() public {
        vm.expectRevert("Block root not set");
        megaEthBridge.unlockNFTWithProof(
            TOKEN_ID_1,
            user1,
            bytes32(uint256(123)),
            1,
            new bytes32[](0)
        );
    }
    
    function test_Revert_DoubleUnlock() public {
        // Setup: Lock and unlock once
        vm.startPrank(user1);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, user1);
        vm.stopPrank();
        
        // First unlock (simplified)
        vm.startPrank(owner);
        megaEthNFT.setBridgeAddress(address(megaEthBridge));
        vm.stopPrank();
        vm.prank(address(megaEthBridge));
        megaEthNFT.bridgeMint(user1, TOKEN_ID_1);
        
        // Try to unlock again
        vm.expectRevert("Token already minted");
        vm.prank(address(megaEthBridge));
        megaEthNFT.bridgeMint(user1, TOKEN_ID_1);
    }
    
    function test_Revert_InvalidRecipient() public {
        vm.startPrank(user1);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        
        vm.expectRevert("Invalid recipient");
        ethBridge.lockNFT(TOKEN_ID_1, address(0));
        
        vm.stopPrank();
    }
}

