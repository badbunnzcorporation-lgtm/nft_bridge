// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./common/BridgeErrors.sol";

interface IEthereumBridge {
    struct LockData {
        uint256 tokenId;
        address owner;
        address recipient;
        uint256 blockNumber;
        bytes32 lockHash;
    }
    
    function getLockData(bytes32 lockHash) external view returns (LockData memory);
    function lockedTokens(uint256 tokenId) external view returns (bool);
}

interface INFT {
    function bridgeMint(address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

contract MegaEthBridge is Ownable, ReentrancyGuard {
    INFT public nftCollection;
    address public ethereumBridge; // Ethereum bridge address on Ethereum
    address public rootSubmitter; // Authorized root submitter
    
    mapping(bytes32 => bool) public processedLocks; // lockHash => processed
    mapping(uint256 => bool) public activeOnMegaETH; // tokenId => is currently active on MegaETH
    mapping(uint256 => bool) public lockedTokens; // tokenId => isLocked (for reverse bridge)
    
    // For merkle proof verification (ETH → MegaETH)
    mapping(uint256 => bytes32) public blockRoots; // blockNumber => merkle root
    mapping(uint256 => bool) public blockRootConsumed; // blockNumber => consumed flag
    
    // For reverse bridge (MegaETH → ETH)
    struct LockData {
        uint256 tokenId;
        address owner;
        address recipient;
        uint256 blockNumber;
        bytes32 lockHash;
    }
    
    mapping(bytes32 => LockData) public lockData; // lockHash => LockData
    
    struct RootMetadata {
        address submitter;
        uint64 submittedAt;
        uint32 lockCount;
    }
    
    mapping(uint256 => RootMetadata) public blockRootMetadata;
    
    event NFTUnlocked(
        uint256 indexed tokenId,
        address indexed recipient,
        bytes32 lockHash
    );
    
    event NFTLocked(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed recipient,
        bytes32 lockHash,
        uint256 blockNumber
    );
    
    event BlockRootSet(uint256 indexed blockNumber, bytes32 root, uint32 lockCount, address indexed submitter);
    event BlockRootCleared(uint256 indexed blockNumber, address indexed clearedBy);
    event RootSubmitterUpdated(address indexed previousSubmitter, address indexed newSubmitter);
    event BridgePaused(address indexed account);
    event BridgeUnpaused(address indexed account);
    
    constructor(address _nftCollection) Ownable() {
        nftCollection = INFT(_nftCollection);
        rootSubmitter = msg.sender;
    }
    
    /**
     * @notice Pause the bridge (emergency stop)
     * @dev Only owner can pause. Prevents new locks but allows unlocks to complete.
     */
    function pause() external onlyOwner {
        _pause();
        emit BridgePaused(msg.sender);
    }
    
    /**
     * @notice Unpause the bridge
     * @dev Only owner can unpause.
     */
    function unpause() external onlyOwner {
        _unpause();
        emit BridgeUnpaused(msg.sender);
    }
    
    /**
     * @notice Check if user has approved this contract to transfer NFTs
     * @param user The user address to check
     * @return True if approved for all, false otherwise
     */
    function isApprovedForAll(address user) external view returns (bool) {
        return IERC721(address(nftCollection)).isApprovedForAll(user, address(this));
    }
    
    /**
     * @notice Check if a specific token is approved for this contract
     * @param tokenId The token ID to check
     * @param owner The owner address
     * @return True if approved, false otherwise
     */
    function isTokenApproved(uint256 tokenId, address owner) external view returns (bool) {
        address approved = IERC721(address(nftCollection)).getApproved(tokenId);
        return approved == address(this) || IERC721(address(nftCollection)).isApprovedForAll(owner, address(this));
    }
    
    modifier onlyRootSubmitter() {
        if (msg.sender != rootSubmitter) {
            revert BridgeUnauthorized(msg.sender);
        }
        _;
    }
    
    function setEthereumBridge(address _ethereumBridge) external onlyOwner {
        ethereumBridge = _ethereumBridge;
    }
    
    function setRootSubmitter(address _newRootSubmitter) external onlyOwner {
        if (_newRootSubmitter == address(0)) {
            revert BridgeInvalidOperation({reason: "Root submitter cannot be zero"});
        }
        emit RootSubmitterUpdated(rootSubmitter, _newRootSubmitter);
        rootSubmitter = _newRootSubmitter;
    }
    
    /**
     * @notice Set merkle root for a block (for trustless verification)
     * Only callable by authorized submitter
     */
    function setBlockRoot(
        uint256 blockNumber,
        bytes32 root,
        uint32 lockCount,
        LockData[] calldata locks
    ) external onlyRootSubmitter {
        if (blockRoots[blockNumber] != bytes32(0)) {
            revert BridgeInvalidOperation({reason: "Root already submitted for block"});
        }
        if (locks.length != lockCount) {
            revert BridgeInvalidOperation({reason: "Lock count mismatch"});
        }
        blockRoots[blockNumber] = root;
        blockRootMetadata[blockNumber] = RootMetadata({
            submitter: msg.sender,
            submittedAt: uint64(block.timestamp),
            lockCount: lockCount
        });
        
        for (uint256 i = 0; i < locks.length; i++) {
            LockData calldata data = locks[i];
            if (data.blockNumber != blockNumber) {
                revert BridgeInvalidOperation({reason: "Lock block mismatch"});
            }
            lockData[data.lockHash] = LockData({
                tokenId: data.tokenId,
                owner: data.owner,
                recipient: data.recipient,
                blockNumber: data.blockNumber,
                lockHash: data.lockHash
            });
        }
        emit BlockRootSet(blockNumber, root, lockCount, msg.sender);
    }
    
    function clearBlockRoot(uint256 blockNumber) external onlyOwner {
        if (blockRoots[blockNumber] == bytes32(0)) {
            revert BridgeInvalidOperation({reason: "Root not set for block"});
        }
        if (blockRootConsumed[blockNumber]) {
            revert BridgeInvalidOperation({reason: "Root already used"});
        }
        delete blockRoots[blockNumber];
        delete blockRootMetadata[blockNumber];
        emit BlockRootCleared(blockNumber, msg.sender);
    }
    
    /**
     * @notice Trustless unlock using merkle proof verification
     * @param tokenId The token ID to mint or unlock
     * @param recipient The address to receive the NFT
     * @param lockHash The lock hash from Ethereum event
     * @param blockNumber The block number where lock occurred
     * @param proof Merkle proof for the lock event
     */
    function unlockNFTWithProof(
        uint256 tokenId,
        address recipient,
        bytes32 lockHash,
        uint256 blockNumber,
        bytes32[] calldata proof
    ) external whenNotPaused nonReentrant {
        require(!processedLocks[lockHash], "Lock already processed");
        require(recipient != address(0), "Invalid recipient");
        require(blockRoots[blockNumber] != bytes32(0), "Block root not set");
        
        LockData memory recorded = lockData[lockHash];
        require(recorded.lockHash == lockHash, "Unknown lock hash");
        require(recorded.tokenId == tokenId, "Token mismatch");
        require(recorded.recipient == recipient, "Recipient mismatch");
        require(recorded.blockNumber == blockNumber, "Block mismatch");
        
        // Create leaf from lock data
        bytes32 leaf = keccak256(
            abi.encodePacked(tokenId, recipient, lockHash, blockNumber)
        );
        
        // Verify merkle proof
        require(
            MerkleProof.verify(proof, blockRoots[blockNumber], leaf),
            "Invalid merkle proof"
        );
        
        blockRootConsumed[blockNumber] = true;
        processedLocks[lockHash] = true;
        delete lockData[lockHash];
        
        // Check if token needs to be minted (first time) or unlocked (returning from ETH)
        if (!activeOnMegaETH[tokenId]) {
            // First time on MegaETH - mint it
            nftCollection.bridgeMint(recipient, tokenId);
            activeOnMegaETH[tokenId] = true;
        } else {
            // Token was previously locked when bridged back to ETH - unlock it
            require(lockedTokens[tokenId], "Token not locked on MegaETH");
            lockedTokens[tokenId] = false;
            nftCollection.transferFrom(address(this), recipient, tokenId);
        }
        
        emit NFTUnlocked(tokenId, recipient, lockHash);
    }
    
    /**
     * @notice Batch unlock with merkle proofs
     */
    function batchUnlockNFTWithProof(
        uint256[] calldata tokenIds,
        address[] calldata recipients,
        bytes32[] calldata lockHashes,
        uint256[] calldata blockNumbers,
        bytes32[][] calldata proofs
    ) external whenNotPaused nonReentrant {
        require(
            tokenIds.length == recipients.length && 
            tokenIds.length == lockHashes.length &&
            tokenIds.length == blockNumbers.length &&
            tokenIds.length == proofs.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < lockHashes.length; i++) {
            require(!processedLocks[lockHashes[i]], "Lock already processed");
            require(blockRoots[blockNumbers[i]] != bytes32(0), "Block root not set");
            
            LockData memory recorded = lockData[lockHashes[i]];
            require(recorded.lockHash == lockHashes[i], "Unknown lock hash");
            require(recorded.tokenId == tokenIds[i], "Token mismatch");
            require(recorded.recipient == recipients[i], "Recipient mismatch");
            require(recorded.blockNumber == blockNumbers[i], "Block mismatch");
            
            bytes32 leaf = keccak256(
                abi.encodePacked(tokenIds[i], recipients[i], lockHashes[i], blockNumbers[i])
            );
            
            require(
                MerkleProof.verify(proofs[i], blockRoots[blockNumbers[i]], leaf),
                "Invalid merkle proof"
            );
            
            blockRootConsumed[blockNumbers[i]] = true;
            processedLocks[lockHashes[i]] = true;
            delete lockData[lockHashes[i]];
            
            // Check if token needs to be minted or unlocked
            if (!activeOnMegaETH[tokenIds[i]]) {
                nftCollection.bridgeMint(recipients[i], tokenIds[i]);
                activeOnMegaETH[tokenIds[i]] = true;
            } else {
                require(lockedTokens[tokenIds[i]], "Token not locked on MegaETH");
                lockedTokens[tokenIds[i]] = false;
                nftCollection.transferFrom(address(this), recipients[i], tokenIds[i]);
            }
            
            emit NFTUnlocked(tokenIds[i], recipients[i], lockHashes[i]);
        }
    }
    
    /**
     * @notice Lock NFT on MegaETH to bridge back to Ethereum
     * @param tokenId The token ID to lock
     * @param recipient The address to receive the NFT on Ethereum
     */
    function lockNFTForEthereum(uint256 tokenId, address recipient) external whenNotPaused nonReentrant {
        require(!lockedTokens[tokenId], "Token already locked");
        require(activeOnMegaETH[tokenId], "Token not active on MegaETH");
        require(recipient != address(0), "Invalid recipient");
        require(nftCollection.ownerOf(tokenId) == msg.sender, "Not token owner");
        
        // Lock the NFT by transferring to bridge contract
        nftCollection.transferFrom(msg.sender, address(this), tokenId);
        
        lockedTokens[tokenId] = true;
        
        // Create unique lock hash
        bytes32 lockHash = keccak256(
            abi.encodePacked(tokenId, msg.sender, recipient, block.number, address(this))
        );
        
        // Store lock data for verification
        lockData[lockHash] = LockData({
            tokenId: tokenId,
            owner: msg.sender,
            recipient: recipient,
            blockNumber: block.number,
            lockHash: lockHash
        });
        
        emit NFTLocked(tokenId, msg.sender, recipient, lockHash, block.number);
    }
    
    /**
     * @notice Batch lock multiple NFTs for Ethereum
     */
    function batchLockNFTForEthereum(
        uint256[] calldata tokenIds,
        address recipient
    ) external whenNotPaused nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(!lockedTokens[tokenIds[i]], "Token already locked");
            require(nftCollection.ownerOf(tokenIds[i]) == msg.sender, "Not token owner");
            
            nftCollection.transferFrom(msg.sender, address(this), tokenIds[i]);
            lockedTokens[tokenIds[i]] = true;
            
            bytes32 lockHash = keccak256(
                abi.encodePacked(tokenIds[i], msg.sender, recipient, block.number, address(this), i)
            );
            
            lockData[lockHash] = LockData({
                tokenId: tokenIds[i],
                owner: msg.sender,
                recipient: recipient,
                blockNumber: block.number,
                lockHash: lockHash
            });
            
            emit NFTLocked(tokenIds[i], msg.sender, recipient, lockHash, block.number);
        }
    }
    
    /**
     * @notice Get lock data for verification (reverse bridge)
     */
    function getLockData(bytes32 lockHash) external view returns (LockData memory) {
        return lockData[lockHash];
    }
}

