// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * Test contract for merkle tree operations
 * This demonstrates proper merkle tree construction and proof generation
 */
contract MerkleTreeTest is Test {
    
    function test_MerkleTree_SingleLeaf() public {
        uint256 tokenId = 1;
        address recipient = address(0x1);
        bytes32 lockHash = keccak256("test");
        uint256 blockNumber = 100;
        
        bytes32 leaf = keccak256(
            abi.encodePacked(tokenId, recipient, lockHash, blockNumber)
        );
        
        // For single leaf, root equals leaf
        bytes32 root = leaf;
        bytes32[] memory proof = new bytes32[](0);
        
        // Verify proof
        assertTrue(MerkleProof.verify(proof, root, leaf));
    }
    
    function test_MerkleTree_TwoLeaves() public {
        // Leaf 1
        bytes32 leaf1 = keccak256(
            abi.encodePacked(uint256(1), address(0x1), keccak256("hash1"), uint256(100))
        );
        
        // Leaf 2
        bytes32 leaf2 = keccak256(
            abi.encodePacked(uint256(2), address(0x2), keccak256("hash2"), uint256(100))
        );
        
        // Root is hash of both leaves
        bytes32 root = keccak256(abi.encodePacked(leaf1, leaf2));
        
        // Proof for leaf1 is leaf2
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2;
        
        // Proof for leaf2 is leaf1
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = leaf1;
        
        // Verify proofs
        assertTrue(MerkleProof.verify(proof1, root, leaf1));
        assertTrue(MerkleProof.verify(proof2, root, leaf2));
    }
    
    function test_MerkleTree_FourLeaves() public {
        // Create 4 leaves
        bytes32[] memory leaves = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(
                    i + 1,
                    address(uint160(i + 1)),
                    keccak256(abi.encodePacked(i)),
                    uint256(100)
                )
            );
        }
        
        // Build tree: [hash(leaf1, leaf2), hash(leaf3, leaf4)]
        bytes32 left = keccak256(abi.encodePacked(leaves[0], leaves[1]));
        bytes32 right = keccak256(abi.encodePacked(leaves[2], leaves[3]));
        bytes32 root = keccak256(abi.encodePacked(left, right));
        
        // Proof for leaf1: [leaf2, right]
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = leaves[1];
        proof1[1] = right;
        
        assertTrue(MerkleProof.verify(proof1, root, leaves[0]));
    }
    
    function test_MerkleProof_InvalidProof() public {
        bytes32 leaf = keccak256("test");
        bytes32 root = keccak256("different");
        bytes32[] memory proof = new bytes32[](0);
        
        // Should fail
        assertFalse(MerkleProof.verify(proof, root, leaf));
    }
}


