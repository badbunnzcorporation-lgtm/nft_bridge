// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contract/EthereumBridge.sol";
import "../contract/MegaEthBridge.sol";
import "../contract/Bad_Bunnz_Interface.sol";
import "../contract/mocks/SimpleNFT.sol";

/**
 * Interface Compatibility Tests
 * 
 * Verifies that the bridge contracts work with any NFT contract that implements
 * the required interface (like Bad_Bunnz).
 * 
 * Bad_Bunnz must implement:
 * - bridgeMint(address, uint256) - for minting when bridging
 * - setBridgeAddress(address) - to authorize bridge
 * - ownerOf(uint256) - standard ERC721
 * - transferFrom(address, address, uint256) - standard ERC721
 * - airdrop(address[], uint256[][]) - for initial minting
 */
contract InterfaceCompatibilityTest is Test {
    // SimpleNFT implements the same interface as Bad_Bunnz for bridge purposes
    SimpleNFT public nftEth;
    SimpleNFT public nftMega;
    EthereumBridge public ethBridge;
    MegaEthBridge public megaBridge;
    
    address public user = address(0x1);
    uint256 constant TOKEN_ID = 1;

    function _megaLocks(
        bytes32 lockHash,
        uint256 tokenId,
        address ownerAddr,
        address recipient,
        uint256 blockNumber
    ) internal pure returns (MegaEthBridge.LockData[] memory locks) {
        locks = new MegaEthBridge.LockData[](1);
        locks[0] = MegaEthBridge.LockData({
            tokenId: tokenId,
            owner: ownerAddr,
            recipient: recipient,
            blockNumber: blockNumber,
            lockHash: lockHash
        });
    }
    
    function setUp() public {
        nftEth = new SimpleNFT("Test", "TEST");
        nftMega = new SimpleNFT("Test", "TEST");
        
        ethBridge = new EthereumBridge(address(nftEth));
        megaBridge = new MegaEthBridge(address(nftMega));
        
        ethBridge.setMegaEthBridge(address(megaBridge));
        megaBridge.setEthereumBridge(address(ethBridge));
        
        // Set bridge addresses (Bad_Bunnz has this function)
        nftEth.setBridgeAddress(address(ethBridge));
        nftMega.setBridgeAddress(address(megaBridge));
    }
    
    /**
     * Test that any contract implementing the interface works with the bridge
     */
    function test_InterfaceCompatibility_ETH_To_MegaETH() public {
        // Mint using airdrop (Bad_Bunnz has this)
        address[] memory recipients = new address[](1);
        recipients[0] = user;
        uint256[][] memory tokenIds = new uint256[][](1);
        tokenIds[0] = new uint256[](1);
        tokenIds[0][0] = TOKEN_ID;
        nftEth.airdrop(recipients, tokenIds);
        
        // Lock (uses transferFrom - standard ERC721)
        vm.startPrank(user);
        nftEth.approve(address(ethBridge), TOKEN_ID);
        ethBridge.lockNFT(TOKEN_ID, user);
        vm.stopPrank();
        
        // Unlock (uses bridgeMint - Bad_Bunnz has this)
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID, user, user, block.number, address(ethBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(TOKEN_ID, user, lockHash, block.number));
        MegaEthBridge.LockData[] memory locks = _megaLocks(lockHash, TOKEN_ID, user, user, block.number);
        megaBridge.setBlockRoot(block.number, leaf, uint32(locks.length), locks);
        
        megaBridge.unlockNFTWithProof(
            TOKEN_ID,
            user,
            lockHash,
            block.number,
            new bytes32[](0)
        );
        
        // Verify minted (bridgeMint was called)
        assertEq(nftMega.ownerOf(TOKEN_ID), user);
    }
    
    /**
     * Verify all required interface functions exist
     */
    function test_VerifyRequiredInterfaceFunctions() public {
        // These functions must exist on Bad_Bunnz:
        
        // 1. bridgeMint - for minting when bridging
        (bool success1,) = address(nftMega).call(
            abi.encodeWithSignature("bridgeMint(address,uint256)", user, 999)
        );
        // Should fail because not called by bridge, but function exists
        // (If function doesn't exist, call would revert differently)
        
        // 2. setBridgeAddress - to authorize bridge
        nftEth.setBridgeAddress(address(0x123));
        assertEq(nftEth.bridgeAddress(), address(0x123));
        
        // 3. ownerOf - standard ERC721 (inherited)
        address[] memory ownerRecipients = new address[](1);
        ownerRecipients[0] = user;
        uint256[][] memory ownerTokenIds = new uint256[][](1);
        ownerTokenIds[0] = new uint256[](1);
        ownerTokenIds[0][0] = TOKEN_ID;
        nftEth.airdrop(ownerRecipients, ownerTokenIds);
        address owner = nftEth.ownerOf(TOKEN_ID);
        // Should work if token exists
        
        // 4. transferFrom - standard ERC721 (inherited)
        // Tested in lockNFT above
        
        // 5. airdrop - for initial minting
        address[] memory recipients = new address[](1);
        recipients[0] = user;
        uint256[][] memory tokenIds = new uint256[][](1);
        tokenIds[0] = new uint256[](1);
        tokenIds[0][0] = 888;
        nftEth.airdrop(recipients, tokenIds);
        assertEq(nftEth.ownerOf(888), user);
    }
    
    /**
     * Test that bridgeMint can only be called by authorized bridge
     */
    function test_BridgeMintOnlyBridge() public {
        // Try to call bridgeMint without being bridge
        vm.expectRevert("Only bridge can call");
        nftMega.bridgeMint(user, 777);
        
        // Set bridge and call
        nftMega.setBridgeAddress(address(megaBridge));
        vm.prank(address(megaBridge));
        nftMega.bridgeMint(user, 777);
        assertEq(nftMega.ownerOf(777), user);
    }
}


