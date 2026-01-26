// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contract/Bad_Bunnz.sol";
import "../contract/EthereumBridge.sol";
import "../contract/MegaEthBridge.sol";
import "../contract/mocks/SimpleNFT.sol";

/**
 * @title BridgeRoundTrip
 * @notice Comprehensive tests for the lock-unlock bridge model including round-trip scenarios
 */
contract BridgeRoundTripTest is Test {
    // Contracts
    SimpleNFT public ethNFT;
    SimpleNFT public megaNFT;
    EthereumBridge public ethBridge;
    MegaEthBridge public megaBridge;
    
    // Test accounts
    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    
    // Test data
    uint256 public constant TOKEN_ID_1 = 1;
    uint256 public constant TOKEN_ID_2 = 2;
    uint256 public constant TOKEN_ID_3 = 3;
    
    // Events to test
    event NFTLocked(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed recipient,
        bytes32 lockHash,
        uint256 blockNumber
    );
    
    event NFTUnlocked(
        uint256 indexed tokenId,
        address indexed recipient,
        bytes32 lockHash
    );
    
    function setUp() public {
        // Deploy Ethereum NFT (simulating existing contract)
        ethNFT = new SimpleNFT("Bad Bunnz", "BUNNZ");
        
        // Deploy MegaETH NFT (using SimpleNFT proxy)
        megaNFT = new SimpleNFT("Bad Bunnz MegaETH", "BBMEGA");
        
        // Deploy bridges
        ethBridge = new EthereumBridge(address(ethNFT));
        megaBridge = new MegaEthBridge(address(megaNFT));
        
        // Configure bridges
        megaNFT.setBridgeAddress(address(megaBridge));
        ethBridge.setMegaEthBridge(address(megaBridge));
        megaBridge.setEthereumBridge(address(ethBridge));
        
        // Mint test NFTs to Alice on Ethereum
        ethNFT.mint(alice, TOKEN_ID_1);
        ethNFT.mint(alice, TOKEN_ID_2);
        ethNFT.mint(alice, TOKEN_ID_3);
        
        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
    }
    
    function test_AirdropRespectsMaxSupply() public {
        Bad_Bunnz.BaseVariables memory baseVars = Bad_Bunnz.BaseVariables({
            name: "Limited Bunnz",
            symbol: "LBUNNZ",
            ownerPayoutAddress: owner,
            initialBaseURI: "ipfs://limited/",
            maxSupply: 1
        });
        Bad_Bunnz limited = new Bad_Bunnz(baseVars, 500);
        
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[][] memory tokenIds = new uint256[][](1);
        tokenIds[0] = new uint256[](1);
        tokenIds[0][0] = 1;
        limited.airdrop(recipients, tokenIds);
        
        tokenIds[0][0] = 2;
        vm.expectRevert(abi.encodeWithSelector(ExceedsMaxSupply.selector, 1, 0));
        limited.airdrop(recipients, tokenIds);
    }
    
    // ==================== FLOW 1: ETH → MegaETH (First Time) ====================
    
    function test_Flow1_LockOnEthereumSuccess() public {
        vm.startPrank(alice);
        
        // Approve bridge
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        
        // Lock NFT
        vm.expectEmit(true, true, true, false);
        emit NFTLocked(TOKEN_ID_1, alice, bob, bytes32(0), block.number);
        ethBridge.lockNFT(TOKEN_ID_1, bob);
        
        vm.stopPrank();
        
        // Verify state
        assertEq(ethNFT.ownerOf(TOKEN_ID_1), address(ethBridge), "NFT should be locked in bridge");
        assertTrue(ethBridge.lockedTokens(TOKEN_ID_1), "Token should be marked as locked");
    }
    
    function test_Flow1_UnlockOnMegaETHFirstTime() public {
        // First lock on Ethereum
        vm.startPrank(alice);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, bob);
        vm.stopPrank();
        
        // Simulate merkle proof verification (in real scenario, this would be generated off-chain)
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, alice, bob, block.number, address(ethBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(TOKEN_ID_1, bob, lockHash, block.number));
        bytes32[] memory proof = new bytes32[](0); // Empty proof for testing
        
        // Set block root (simulate relayer)
        MegaEthBridge.LockData[] memory locks = new MegaEthBridge.LockData[](1);
        locks[0] = MegaEthBridge.LockData({
            tokenId: TOKEN_ID_1,
            owner: alice,
            recipient: bob,
            blockNumber: block.number,
            lockHash: lockHash
        });
        megaBridge.setBlockRoot(block.number, leaf, uint32(locks.length), locks);
        
        // Unlock on MegaETH
        vm.expectEmit(true, true, true, false);
        emit NFTUnlocked(TOKEN_ID_1, bob, lockHash);
        megaBridge.unlockNFTWithProof(TOKEN_ID_1, bob, lockHash, block.number, proof);
        
        // Verify state
        assertEq(megaNFT.ownerOf(TOKEN_ID_1), bob, "Bob should own NFT on MegaETH");
        assertTrue(megaBridge.activeOnMegaETH(TOKEN_ID_1), "Token should be active on MegaETH");
        assertFalse(megaBridge.lockedTokens(TOKEN_ID_1), "Token should not be locked");
        assertTrue(megaBridge.processedLocks(lockHash), "Lock should be processed");
    }
    
    function test_Flow1_CannotUnlockTwice() public {
        // Lock and unlock once
        vm.startPrank(alice);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, bob);
        vm.stopPrank();
        
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, alice, bob, block.number, address(ethBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(TOKEN_ID_1, bob, lockHash, block.number));
        bytes32[] memory proof = new bytes32[](0);
        
        MegaEthBridge.LockData[] memory locks = new MegaEthBridge.LockData[](1);
        locks[0] = MegaEthBridge.LockData({
            tokenId: TOKEN_ID_1,
            owner: alice,
            recipient: bob,
            blockNumber: block.number,
            lockHash: lockHash
        });
        megaBridge.setBlockRoot(block.number, leaf, uint32(locks.length), locks);
        megaBridge.unlockNFTWithProof(TOKEN_ID_1, bob, lockHash, block.number, proof);
        
        // Try to unlock again
        vm.expectRevert("Lock already processed");
        megaBridge.unlockNFTWithProof(TOKEN_ID_1, bob, lockHash, block.number, proof);
    }
    
    // ==================== FLOW 2: MegaETH → ETH (Bridge Back) ====================
    
    function test_Flow2_LockOnMegaETHSuccess() public {
        // First bridge to MegaETH
        _bridgeToMegaETH(alice, bob, TOKEN_ID_1);
        
        // Now lock on MegaETH to bridge back
        vm.roll(block.number + 1);
        vm.startPrank(bob);
        megaNFT.approve(address(megaBridge), TOKEN_ID_1);
        
        megaBridge.lockNFTForEthereum(TOKEN_ID_1, charlie);
        
        vm.stopPrank();
        
        // Verify state
        assertEq(megaNFT.ownerOf(TOKEN_ID_1), address(megaBridge), "NFT should be locked in bridge");
        assertTrue(megaBridge.lockedTokens(TOKEN_ID_1), "Token should be marked as locked");
        assertTrue(megaBridge.activeOnMegaETH(TOKEN_ID_1), "Token should still be active on MegaETH");
    }
    
    function test_Flow2_UnlockOnEthereumSuccess() public {
        // Bridge to MegaETH then lock on MegaETH
        _bridgeToMegaETH(alice, bob, TOKEN_ID_1);
        
        vm.startPrank(bob);
        megaNFT.approve(address(megaBridge), TOKEN_ID_1);
        uint256 lockBlock = block.number;
        megaBridge.lockNFTForEthereum(TOKEN_ID_1, charlie);
        vm.stopPrank();
        
        // Simulate merkle proof for reverse bridge
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, bob, charlie, lockBlock, address(megaBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(TOKEN_ID_1, charlie, lockHash, lockBlock));
        bytes32[] memory proof = new bytes32[](0);
        
        // Set block root on Ethereum
        _setEthRootSingle(lockHash, TOKEN_ID_1, bob, charlie, lockBlock, leaf);
        
        // Unlock on Ethereum
        vm.expectEmit(true, true, true, false);
        emit NFTUnlocked(TOKEN_ID_1, charlie, lockHash);
        ethBridge.unlockNFTWithProof(TOKEN_ID_1, charlie, lockHash, lockBlock, proof);
        
        // Verify state
        assertEq(ethNFT.ownerOf(TOKEN_ID_1), charlie, "Charlie should own NFT on Ethereum");
        assertFalse(ethBridge.lockedTokens(TOKEN_ID_1), "Token should not be locked on Ethereum");
        assertTrue(ethBridge.processedLocks(lockHash), "Lock should be processed");
    }
    
    function test_Flow2_CannotLockIfNotActive() public {
        // Try to lock a token that was never bridged to MegaETH
        vm.startPrank(alice);
        vm.expectRevert("Token not active on MegaETH");
        megaBridge.lockNFTForEthereum(TOKEN_ID_1, bob);
        vm.stopPrank();
    }
    
    // ==================== FLOW 3: ETH → MegaETH (Round-Trip) ====================
    
    function test_Flow3_RoundTripSuccess() public {
        // Step 1: Bridge to MegaETH (first time)
        _bridgeToMegaETH(alice, bob, TOKEN_ID_1);
        assertEq(megaNFT.ownerOf(TOKEN_ID_1), bob, "Bob should own on MegaETH");
        
        // Step 2: Bridge back to Ethereum
        _bridgeToEthereum(bob, charlie, TOKEN_ID_1);
        assertEq(ethNFT.ownerOf(TOKEN_ID_1), charlie, "Charlie should own on Ethereum");
        assertTrue(megaBridge.lockedTokens(TOKEN_ID_1), "Token remains locked on MegaETH until returned");
        
        // Step 3: Bridge to MegaETH again (round-trip)
        vm.roll(block.number + 1);
        vm.startPrank(charlie);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        uint256 lockBlock = block.number;
        ethBridge.lockNFT(TOKEN_ID_1, alice);
        vm.stopPrank();
        
        // Generate proof and unlock
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID_1, charlie, alice, lockBlock, address(ethBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(TOKEN_ID_1, alice, lockHash, lockBlock));
        bytes32[] memory proof = new bytes32[](0);
        
        _setMegaRootSingle(lockHash, TOKEN_ID_1, charlie, alice, lockBlock, leaf);
        megaBridge.unlockNFTWithProof(TOKEN_ID_1, alice, lockHash, lockBlock, proof);
        
        // Verify: Token should be UNLOCKED, not minted again
        assertEq(megaNFT.ownerOf(TOKEN_ID_1), alice, "Alice should own NFT on MegaETH");
        assertTrue(megaBridge.activeOnMegaETH(TOKEN_ID_1), "Token should still be active");
        assertFalse(megaBridge.lockedTokens(TOKEN_ID_1), "Token should be unlocked");
    }
    
    function test_Flow3_MultipleRoundTrips() public {
        // Round-trip 1: ETH → Mega → ETH
        _bridgeToMegaETH(alice, bob, TOKEN_ID_1);
        _bridgeToEthereum(bob, charlie, TOKEN_ID_1);
        
        // Round-trip 2: ETH → Mega → ETH
        _bridgeToMegaETH(charlie, alice, TOKEN_ID_1);
        _bridgeToEthereum(alice, bob, TOKEN_ID_1);
        
        // Round-trip 3: ETH → Mega
        _bridgeToMegaETH(bob, charlie, TOKEN_ID_1);
        
        // Verify final state
        assertEq(megaNFT.ownerOf(TOKEN_ID_1), charlie, "Charlie should own on MegaETH");
        assertTrue(megaBridge.activeOnMegaETH(TOKEN_ID_1), "Token should be active");
        assertFalse(megaBridge.lockedTokens(TOKEN_ID_1), "Token should not be locked");
    }
    
    // ==================== BATCH OPERATIONS ====================
    
    function test_BatchLockOnEthereum() public {
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = TOKEN_ID_1;
        tokenIds[1] = TOKEN_ID_2;
        tokenIds[2] = TOKEN_ID_3;
        
        vm.startPrank(alice);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethNFT.approve(address(ethBridge), TOKEN_ID_2);
        ethNFT.approve(address(ethBridge), TOKEN_ID_3);
        
        ethBridge.batchLockNFT(tokenIds, bob);
        vm.stopPrank();
        
        // Verify all locked
        assertTrue(ethBridge.lockedTokens(TOKEN_ID_1), "Token 1 should be locked");
        assertTrue(ethBridge.lockedTokens(TOKEN_ID_2), "Token 2 should be locked");
        assertTrue(ethBridge.lockedTokens(TOKEN_ID_3), "Token 3 should be locked");
    }
    
    function test_BatchUnlockOnMegaETH() public {
        // Lock multiple tokens on Ethereum
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_1;
        tokenIds[1] = TOKEN_ID_2;
        
        vm.startPrank(alice);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethNFT.approve(address(ethBridge), TOKEN_ID_2);
        uint256 lockBlock = block.number;
        ethBridge.batchLockNFT(tokenIds, bob);
        vm.stopPrank();
        
        // Prepare batch unlock data
        address[] memory recipients = new address[](2);
        recipients[0] = bob;
        recipients[1] = bob;
        
        bytes32[] memory lockHashes = new bytes32[](2);
        lockHashes[0] = keccak256(abi.encodePacked(TOKEN_ID_1, alice, bob, lockBlock, address(ethBridge), uint256(0)));
        lockHashes[1] = keccak256(abi.encodePacked(TOKEN_ID_2, alice, bob, lockBlock, address(ethBridge), uint256(1)));
        
        uint256[] memory blockNumbers = new uint256[](2);
        blockNumbers[0] = lockBlock;
        blockNumbers[1] = lockBlock;
        
        // Build merkle tree for two leaves
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(TOKEN_ID_1, bob, lockHashes[0], lockBlock));
        leaves[1] = keccak256(abi.encodePacked(TOKEN_ID_2, bob, lockHashes[1], lockBlock));
        bytes32 root = leaves[0] < leaves[1]
            ? keccak256(abi.encodePacked(leaves[0], leaves[1]))
            : keccak256(abi.encodePacked(leaves[1], leaves[0]));
        
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = leaves[1];
        proofs[1] = new bytes32[](1);
        proofs[1][0] = leaves[0];
        
        MegaEthBridge.LockData[] memory locks = new MegaEthBridge.LockData[](2);
        locks[0] = MegaEthBridge.LockData({
            tokenId: TOKEN_ID_1,
            owner: alice,
            recipient: bob,
            blockNumber: lockBlock,
            lockHash: lockHashes[0]
        });
        locks[1] = MegaEthBridge.LockData({
            tokenId: TOKEN_ID_2,
            owner: alice,
            recipient: bob,
            blockNumber: lockBlock,
            lockHash: lockHashes[1]
        });
        megaBridge.setBlockRoot(lockBlock, root, uint32(locks.length), locks);
        
        // Batch unlock
        megaBridge.batchUnlockNFTWithProof(tokenIds, recipients, lockHashes, blockNumbers, proofs);
        
        // Verify both unlocked
        assertEq(megaNFT.ownerOf(TOKEN_ID_1), bob, "Bob should own token 1");
        assertEq(megaNFT.ownerOf(TOKEN_ID_2), bob, "Bob should own token 2");
    }
    
    // ==================== EDGE CASES ====================
    
    function test_CannotLockAlreadyLockedToken() public {
        vm.startPrank(alice);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, bob);
        
        vm.expectRevert("Token already locked");
        ethBridge.lockNFT(TOKEN_ID_1, bob);
        vm.stopPrank();
    }
    
    function test_CannotUnlockWithInvalidProof() public {
        vm.startPrank(alice);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, bob);
        vm.stopPrank();
        
        bytes32 lockHash = keccak256(abi.encodePacked(TOKEN_ID_1, alice, bob, block.number, address(ethBridge)));
        bytes32[] memory proof = new bytes32[](0);
        
        // Set wrong block root
        _setMegaRootSingle(lockHash, TOKEN_ID_1, alice, bob, block.number, bytes32(uint256(123)));
        
        vm.expectRevert("Invalid merkle proof");
        megaBridge.unlockNFTWithProof(TOKEN_ID_1, bob, lockHash, block.number, proof);
    }
    
    function test_CannotUnlockWithoutBlockRoot() public {
        vm.startPrank(alice);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        ethBridge.lockNFT(TOKEN_ID_1, bob);
        vm.stopPrank();
        
        bytes32 lockHash = keccak256(abi.encodePacked(TOKEN_ID_1, alice, bob, block.number, address(ethBridge)));
        bytes32[] memory proof = new bytes32[](0);
        
        vm.expectRevert("Block root not set");
        megaBridge.unlockNFTWithProof(TOKEN_ID_1, bob, lockHash, block.number, proof);
    }
    
    function test_CannotLockToZeroAddress() public {
        vm.startPrank(alice);
        ethNFT.approve(address(ethBridge), TOKEN_ID_1);
        
        vm.expectRevert("Invalid recipient");
        ethBridge.lockNFT(TOKEN_ID_1, address(0));
        vm.stopPrank();
    }
    
    function test_CannotLockTokenYouDontOwn() public {
        vm.startPrank(bob);
        
        vm.expectRevert();
        ethBridge.lockNFT(TOKEN_ID_1, charlie);
        vm.stopPrank();
    }
    
    // ==================== HELPER FUNCTIONS ====================
    
    function _setMegaRootSingle(
        bytes32 lockHash,
        uint256 tokenId,
        address owner_,
        address recipient_,
        uint256 blockNumber,
        bytes32 root
    ) internal {
        MegaEthBridge.LockData[] memory locks = new MegaEthBridge.LockData[](1);
        locks[0] = MegaEthBridge.LockData({
            tokenId: tokenId,
            owner: owner_,
            recipient: recipient_,
            blockNumber: blockNumber,
            lockHash: lockHash
        });
        megaBridge.setBlockRoot(blockNumber, root, uint32(locks.length), locks);
    }
    
    function _setEthRootSingle(
        bytes32 lockHash,
        uint256 tokenId,
        address owner_,
        address recipient_,
        uint256 blockNumber,
        bytes32 root
    ) internal {
        EthereumBridge.LockData[] memory locks = new EthereumBridge.LockData[](1);
        locks[0] = EthereumBridge.LockData({
            tokenId: tokenId,
            owner: owner_,
            recipient: recipient_,
            blockNumber: blockNumber,
            lockHash: lockHash
        });
        ethBridge.setMegaEthBlockRoot(blockNumber, root, uint32(locks.length), locks);
    }
    
    function _bridgeToMegaETH(address from, address to, uint256 tokenId) internal {
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
        bytes32[] memory proof = new bytes32[](0);
        
        _setMegaRootSingle(lockHash, tokenId, from, to, lockBlock, leaf);
        megaBridge.unlockNFTWithProof(tokenId, to, lockHash, lockBlock, proof);
    }
    
    function _bridgeToEthereum(address from, address to, uint256 tokenId) internal {
        vm.roll(block.number + 1);
        vm.startPrank(from);
        megaNFT.approve(address(megaBridge), tokenId);
        uint256 lockBlock = block.number;
        megaBridge.lockNFTForEthereum(tokenId, to);
        vm.stopPrank();
        
        bytes32 lockHash = keccak256(
            abi.encodePacked(tokenId, from, to, lockBlock, address(megaBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, to, lockHash, lockBlock));
        bytes32[] memory proof = new bytes32[](0);
        
        _setEthRootSingle(lockHash, tokenId, from, to, lockBlock, leaf);
        ethBridge.unlockNFTWithProof(tokenId, to, lockHash, lockBlock, proof);
    }
}
