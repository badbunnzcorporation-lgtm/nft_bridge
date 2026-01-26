// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IBadBunnz
 * @notice Interface for Bad_Bunnz NFT contract required by the bridge
 * @dev Any NFT contract implementing this interface can work with the bridge
 */
interface IBadBunnz {
    /**
     * @notice Mint NFT from bridge (only callable by authorized bridge)
     * @param to Address to mint to
     * @param tokenId Token ID to mint
     */
    function bridgeMint(address to, uint256 tokenId) external;
    
    /**
     * @notice Burn NFT from bridge (only callable by authorized bridge)
     * @param tokenId Token ID to burn
     */
    function bridgeBurn(uint256 tokenId) external;
    
    /**
     * @notice Set the authorized bridge address
     * @param _bridgeAddress Address of the bridge contract
     */
    function setBridgeAddress(address _bridgeAddress) external;
    
    /**
     * @notice Get the current bridge address
     * @return Address of the authorized bridge
     */
    function bridgeAddress() external view returns (address);
    
    /**
     * @notice Standard ERC721 ownerOf
     * @param tokenId Token ID to query
     * @return Address of the token owner
     */
    function ownerOf(uint256 tokenId) external view returns (address);
    
    /**
     * @notice Standard ERC721 transferFrom
     * @param from Address to transfer from
     * @param to Address to transfer to
     * @param tokenId Token ID to transfer
     */
    function transferFrom(address from, address to, uint256 tokenId) external;
    
    /**
     * @notice Batch airdrop function for initial minting
     * @param recipients Array of recipient addresses
     * @param tokenIds 2D array of token IDs for each recipient
     */
    function airdrop(
        address[] calldata recipients,
        uint256[][] calldata tokenIds
    ) external;
}

