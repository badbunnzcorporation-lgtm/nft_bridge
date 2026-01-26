// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721C, ERC721OpenZeppelin} from "@limitbreak/creator-token-standards/src/erc721c/ERC721C.sol";
import {ERC2981, BasicRoyalties} from "@limitbreak/creator-token-standards/src/programmable-royalties/BasicRoyalties.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

error Unauthorized(address caller);
error InvalidOperation(string reason);
error ExceedsMaxSupply(uint256 requested, uint256 available);

contract Bad_Bunnz is ERC721C, IERC721Enumerable, BasicRoyalties, Ownable {
    event BatchMetadataUpdate(
        uint256 indexed fromTokenId,
        uint256 indexed toTokenId
    );

    event Airdropped(
        address indexed recipient,
        uint256 amount,
        uint256 tokenId
    );

    struct BaseVariables {
        string name;
        string symbol;
        address ownerPayoutAddress;
        string initialBaseURI;
        uint256 maxSupply;
    }

    //Base variables
    uint256 public maxSupply;
    string public baseURI;
    address public ownerPayoutAddress;
    uint256 public mintedSupply;
    
    // Bridge variables
    address public bridgeAddress;
    event BridgeAddressUpdated(address indexed previousBridge, address indexed newBridge);

    constructor(
        //Base variables
        BaseVariables memory _baseVariables,
        //Royalties variables
        uint96 _royaltyPercentage
    )
        ERC721OpenZeppelin(_baseVariables.name, _baseVariables.symbol)
        Ownable()
        BasicRoyalties(_baseVariables.ownerPayoutAddress, _royaltyPercentage)
    {
        //Base variables
        maxSupply = _baseVariables.maxSupply;
        baseURI = _baseVariables.initialBaseURI;
        ownerPayoutAddress = _baseVariables.ownerPayoutAddress;
        mintedSupply = 0;
    }

    // Sets the base URI for the token metadata. Only the contract owner can call this function.
    function setBaseURI(string memory newBaseURI) public onlyOwner {
        baseURI = newBaseURI;
        emit BatchMetadataUpdate(1, type(uint256).max); // Signal that all token metadata has been updated
    }

    // Returns the base URI for the token metadata.
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    mapping(address => mapping(uint256 => uint256)) private _ownedTokens;
    mapping(uint256 => uint256) private _ownedTokensIndex;
    uint256[] private _allTokens;
    mapping(uint256 => uint256) private _allTokensIndex;

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(IERC165, ERC721C, ERC2981) returns (bool) {
        return
            interfaceId == type(IERC721Enumerable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _requireCallerIsContractOwner() internal view virtual override {
        _checkOwner();
    }

    function setDefaultRoyalty(
        address receiver,
        uint96 feeNumerator
    ) external onlyOwner {
        _requireCallerIsContractOwner();
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function setTokenRoyalty(
        uint256 tokenId,
        address receiver,
        uint96 feeNumerator
    ) external onlyOwner {
        _requireCallerIsContractOwner();
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
    }

    modifier onlyBridge() {
        if (msg.sender != bridgeAddress) revert Unauthorized(msg.sender);
        _;
    }

    function setBridgeAddress(address _bridgeAddress) external onlyOwner {
        if (_bridgeAddress == address(0)) {
            revert InvalidOperation({reason: "Bridge address cannot be zero"});
        }
        if (bridgeAddress != address(0)) {
            revert InvalidOperation({reason: "Bridge address already set"});
        }
        emit BridgeAddressUpdated(bridgeAddress, _bridgeAddress);
        bridgeAddress = _bridgeAddress;
    }

    function bridgeMint(address to, uint256 tokenId) external onlyBridge {
        _safeMint(to, tokenId);
    }

    function bridgeBurn(uint256 tokenId) external onlyBridge {
        _burn(tokenId);
    }

    function totalSupply() public view override returns (uint256) {
        return _allTokens.length;
    }

    function tokenOfOwnerByIndex(
        address owner,
        uint256 index
    ) public view override returns (uint256) {
        if (index >= balanceOf(owner)) {
            revert InvalidOperation({reason: "Owner index out of bounds"});
        }
        return _ownedTokens[owner][index];
    }

    function tokenByIndex(uint256 index) public view override returns (uint256) {
        if (index >= totalSupply()) {
            revert InvalidOperation({reason: "Global index out of bounds"});
        }
        return _allTokens[index];
    }

    function tokensOfOwner(
        address owner
    ) external view returns (uint256[] memory tokenIds) {
        uint256 balance = balanceOf(owner);
        tokenIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        }
    }

    function airdrop(
        address[] calldata recipients,
        uint256[][] calldata tokenIds
    ) external onlyOwner {
        if (recipients.length != tokenIds.length) {
            revert InvalidOperation({
                reason: "Recipients and tokenIds arrays must have the same length"
            });
        }

        // Calculate total tokens to mint
        uint256 totalToMint = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            totalToMint += tokenIds[i].length;
        }

        // Check max supply before minting
        if (mintedSupply + totalToMint > maxSupply) {
            revert ExceedsMaxSupply({
                requested: totalToMint,
                available: maxSupply - mintedSupply
            });
        }

        // Mint tokens
        for (uint256 i = 0; i < recipients.length; i++) {
            for (uint256 j = 0; j < tokenIds[i].length; j++) {
                _safeMint(recipients[i], tokenIds[i][j]);
                emit Airdropped(recipients[i], tokenIds[i][j], tokenIds[i][j]);
            }
        }
        mintedSupply += totalToMint;
    }
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal virtual override(ERC721C) {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);

        if (batchSize > 1) {
            revert InvalidOperation({reason: "Consecutive transfers not supported"});
        }

        uint256 tokenId = firstTokenId;

        if (from == address(0)) {
            _addTokenToAllTokensEnumeration(tokenId);
        } else if (from != to) {
            _removeTokenFromOwnerEnumeration(from, tokenId);
        }

        if (to == address(0)) {
            _removeTokenFromAllTokensEnumeration(tokenId);
        } else if (to != from) {
            _addTokenToOwnerEnumeration(to, tokenId);
        }
    }

    function _addTokenToOwnerEnumeration(address to, uint256 tokenId) private {
        uint256 length = balanceOf(to);
        _ownedTokens[to][length] = tokenId;
        _ownedTokensIndex[tokenId] = length;
    }

    function _addTokenToAllTokensEnumeration(uint256 tokenId) private {
        _allTokensIndex[tokenId] = _allTokens.length;
        _allTokens.push(tokenId);
    }

    function _removeTokenFromOwnerEnumeration(address from, uint256 tokenId) private {
        uint256 lastTokenIndex = balanceOf(from) - 1;
        uint256 tokenIndex = _ownedTokensIndex[tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = _ownedTokens[from][lastTokenIndex];

            _ownedTokens[from][tokenIndex] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = tokenIndex;
        }

        delete _ownedTokensIndex[tokenId];
        delete _ownedTokens[from][lastTokenIndex];
    }

    function _removeTokenFromAllTokensEnumeration(uint256 tokenId) private {
        uint256 lastTokenIndex = _allTokens.length - 1;
        uint256 tokenIndex = _allTokensIndex[tokenId];
        uint256 lastTokenId = _allTokens[lastTokenIndex];

        _allTokens[tokenIndex] = lastTokenId;
        _allTokensIndex[lastTokenId] = tokenIndex;

        delete _allTokensIndex[tokenId];
        _allTokens.pop();
    }
}