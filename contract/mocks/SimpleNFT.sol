// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Simplified NFT contract for testing
 * Replaces Bad_Bunnz for tests that don't need Limit Break features
 */
contract SimpleNFT is ERC721, Ownable {
    uint256 public maxSupply;
    string private _baseTokenURI;
    address public bridgeAddress;
    
    mapping(uint256 => bool) public minted;
    
    event Airdropped(address indexed recipient, uint256 indexed tokenId);
    
    constructor(
        string memory name,
        string memory symbol
    ) ERC721(name, symbol) Ownable() {
        maxSupply = 10000;
        _baseTokenURI = "ipfs://test/";
    }
    
    // Simplified mint for testing
    function mint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
    
    function setBaseURI(string memory newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
    }
    
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
    
    function setBridgeAddress(address _bridgeAddress) external onlyOwner {
        bridgeAddress = _bridgeAddress;
    }
    
    modifier onlyBridge() {
        require(msg.sender == bridgeAddress, "Only bridge can call");
        _;
    }
    
    function bridgeMint(address to, uint256 tokenId) external onlyBridge {
        require(!minted[tokenId], "Token already minted");
        minted[tokenId] = true;
        _safeMint(to, tokenId);
        emit Airdropped(to, tokenId);
    }
    
    function airdrop(
        address[] calldata recipients,
        uint256[][] calldata tokenIds
    ) external onlyOwner {
        require(recipients.length == tokenIds.length, "Array length mismatch");
        
        for (uint256 i = 0; i < recipients.length; i++) {
            for (uint256 j = 0; j < tokenIds[i].length; j++) {
                require(!minted[tokenIds[i][j]], "Token already minted");
                minted[tokenIds[i][j]] = true;
                _safeMint(recipients[i], tokenIds[i][j]);
                emit Airdropped(recipients[i], tokenIds[i][j]);
            }
        }
    }
}

