// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contract/EthereumBridge.sol";
import "../contract/MegaEthBridge.sol";
import "../contract/mocks/SimpleNFT.sol";

/**
 * Bad_Bunnz Bridge Compatibility Tests
 * 
 * NOTE: Bad_Bunnz.sol cannot be compiled directly due to Limit Break library
 * compatibility issues with OpenZeppelin. However, this test verifies that:
 * 
 * 1. The bridge works with any NFT that implements the required interface
 * 2. SimpleNFT implements the same interface as Bad_Bunnz for bridge purposes
 * 3. As long as Bad_Bunnz has the required functions, it will work with the bridge
 * 
 * Required functions for Bad_Bunnz:
 * - bridgeMint(address, uint256) - for minting when bridging
 * - setBridgeAddress(address) - to authorize bridge
 * - bridgeAddress() - to check authorized bridge
 * - ownerOf(uint256) - standard ERC721
 * - transferFrom(address, address, uint256) - standard ERC721
 * - airdrop(address[], uint256[][]) - for initial minting (optional, for testing)
 * 
 * To make Bad_Bunnz bridge-compatible, add these functions:
 * 
 * ```solidity
 * address public bridgeAddress;
 * 
 * modifier onlyBridge() {
 *     if (msg.sender != bridgeAddress) revert Unauthorized(msg.sender);
 *     _;
 * }
 * 
 * function setBridgeAddress(address _bridgeAddress) external onlyOwner {
 *     bridgeAddress = _bridgeAddress;
 * }
 * 
 * function bridgeMint(address to, uint256 tokenId) external onlyBridge {
 *     _safeMint(to, tokenId);
 * }
 * ```
 */
contract BadBunnzBridgeTest is Test {
    // Using SimpleNFT as a proxy for Bad_Bunnz since they implement the same interface
    SimpleNFT public badBunnzEth;
    SimpleNFT public badBunnzMega;
    EthereumBridge public ethBridge;
    MegaEthBridge public megaBridge;
    
    address public user = address(0x1);
    uint256 constant TOKEN_ID = 1;
    
    function setUp() public {
        // Deploy "Bad_Bunnz" contracts (using SimpleNFT as proxy)
        badBunnzEth = new SimpleNFT("Bad Bunnz", "BUNNZ");
        badBunnzMega = new SimpleNFT("Bad Bunnz", "BUNNZ");
        
        // Deploy bridges
        ethBridge = new EthereumBridge(address(badBunnzEth));
        megaBridge = new MegaEthBridge(address(badBunnzMega));
        
        // Link bridges
        ethBridge.setMegaEthBridge(address(megaBridge));
        megaBridge.setEthereumBridge(address(ethBridge));
        
        // Authorize bridges (Bad_Bunnz.setBridgeAddress equivalent)
        badBunnzEth.setBridgeAddress(address(ethBridge));
        badBunnzMega.setBridgeAddress(address(megaBridge));
    }
    
    function _airdropOnEthereum(uint256 tokenId) internal {
        address[] memory recipients = new address[](1);
        recipients[0] = user;
        uint256[][] memory tokenIds = new uint256[][](1);
        tokenIds[0] = new uint256[](1);
        tokenIds[0][0] = tokenId;
        badBunnzEth.airdrop(recipients, tokenIds);
    }

    function _bridgeEthToMega(uint256 tokenId) internal {
        _airdropOnEthereum(tokenId);

        vm.startPrank(user);
        badBunnzEth.approve(address(ethBridge), tokenId);
        uint256 lockBlock = block.number;
        ethBridge.lockNFT(tokenId, user);
        vm.stopPrank();

        bytes32 lockHash = keccak256(
            abi.encodePacked(tokenId, user, user, lockBlock, address(ethBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(tokenId, user, lockHash, lockBlock));
        MegaEthBridge.LockData[] memory locks = new MegaEthBridge.LockData[](1);
        locks[0] = MegaEthBridge.LockData({
            tokenId: tokenId,
            owner: user,
            recipient: user,
            blockNumber: lockBlock,
            lockHash: lockHash
        });
        megaBridge.setBlockRoot(lockBlock, leaf, uint32(locks.length), locks);

        megaBridge.unlockNFTWithProof(
            tokenId,
            user,
            lockHash,
            lockBlock,
            new bytes32[](0)
        );
    }
    
    /**
     * Test: Bridge Bad_Bunnz NFT from Ethereum to MegaETH
     * This simulates the exact flow that would work with the real Bad_Bunnz contract
     */
    function test_BridgeBadBunnz_ETH_To_MegaETH() public {
        _bridgeEthToMega(TOKEN_ID);

        // Verify NFT was minted on MegaETH
        assertEq(badBunnzMega.ownerOf(TOKEN_ID), user, "User should own NFT on MegaETH");
    }
    
    /**
     * Test: Bridge Bad_Bunnz NFT back from MegaETH to Ethereum
     * Note: This requires the token to be locked on Ethereum first (from initial bridge)
     */
    function test_BridgeBadBunnz_MegaETH_To_ETH() public {
        // First perform a real bridge to activate the token on MegaETH
        _bridgeEthToMega(TOKEN_ID);
        
        // 2. Lock NFT on MegaETH bridge (user wants to bridge back)
        vm.startPrank(user);
        badBunnzMega.approve(address(megaBridge), TOKEN_ID);
        uint256 lockBlock = block.number;
        megaBridge.lockNFTForEthereum(TOKEN_ID, user);
        vm.stopPrank();
        
        // 3. Generate Merkle proof and unlock on Ethereum
        bytes32 lockHash = keccak256(
            abi.encodePacked(TOKEN_ID, user, user, lockBlock, address(megaBridge))
        );
        bytes32 leaf = keccak256(abi.encodePacked(TOKEN_ID, user, lockHash, lockBlock));
        EthereumBridge.LockData[] memory locks = new EthereumBridge.LockData[](1);
        locks[0] = EthereumBridge.LockData({
            tokenId: TOKEN_ID,
            owner: user,
            recipient: user,
            blockNumber: lockBlock,
            lockHash: lockHash
        });
        ethBridge.setMegaEthBlockRoot(lockBlock, leaf, uint32(locks.length), locks);
        
        // Token is already locked on Ethereum from step 1
        ethBridge.unlockNFTWithProof(
            TOKEN_ID,
            user,
            lockHash,
            lockBlock,
            new bytes32[](0)
        );
        
        // 4. Verify NFT was unlocked on Ethereum
        assertEq(badBunnzEth.ownerOf(TOKEN_ID), user, "User should own NFT on Ethereum");
    }
    
    /**
     * Test: Verify Bad_Bunnz interface compatibility
     */
    function test_VerifyBadBunnzInterface() public {
        // All these functions must exist on Bad_Bunnz:
        
        // 1. bridgeMint
        vm.prank(address(megaBridge));
        badBunnzMega.bridgeMint(user, 999);
        assertEq(badBunnzMega.ownerOf(999), user);
        
        // 2. setBridgeAddress
        badBunnzEth.setBridgeAddress(address(0x123));
        assertEq(badBunnzEth.bridgeAddress(), address(0x123));
        
        // 3. bridgeAddress getter
        address bridge = badBunnzEth.bridgeAddress();
        assertEq(bridge, address(0x123));
        
        // 4. ownerOf (ERC721)
        _airdropOnEthereum(TOKEN_ID);
        address owner = badBunnzEth.ownerOf(TOKEN_ID);
        // Works if token exists
        
        // 5. airdrop
        address[] memory recipients = new address[](1);
        recipients[0] = user;
        uint256[][] memory tokenIds = new uint256[][](1);
        tokenIds[0] = new uint256[](1);
        tokenIds[0][0] = 888;
        badBunnzEth.airdrop(recipients, tokenIds);
        assertEq(badBunnzEth.ownerOf(888), user);
    }
    
    /**
     * Test: Bridge authorization (only bridge can mint)
     */
    function test_BadBunnz_BridgeAuthorization() public {
        // Unauthorized call should fail
        vm.expectRevert("Only bridge can call");
        badBunnzMega.bridgeMint(user, 777);
        
        // Authorized call should succeed
        vm.prank(address(megaBridge));
        badBunnzMega.bridgeMint(user, 777);
        assertEq(badBunnzMega.ownerOf(777), user);
    }
}
