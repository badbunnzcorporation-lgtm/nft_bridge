const { expect } = require("chai");
const { ethers } = require("hardhat");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");

const buildLockStruct = (tokenId, owner, recipient, blockNumber, lockHash) => ({
  tokenId,
  owner,
  recipient,
  blockNumber,
  lockHash,
});

describe("Bad_Bunnz Bridge End-to-End Tests", function () {
  let badBunnzEth, badBunnzMega;
  let ethBridge, megaBridge;
  let owner, user1, user2;
  
  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();
    
    // Deploy proxy NFT contracts (SimpleNFT implements required interface)
    const SimpleNFT = await ethers.getContractFactory("SimpleNFT");
    badBunnzEth = await SimpleNFT.deploy("Bad Bunnz", "BUNNZ");
    await badBunnzEth.waitForDeployment();

    // Deploy "Bad_Bunnz" on MegaETH (simulated as another deployment)
    badBunnzMega = await SimpleNFT.deploy("Bad Bunnz", "BUNNZ");
    await badBunnzMega.waitForDeployment();

    // Deploy Ethereum Bridge
    const EthereumBridge = await ethers.getContractFactory("EthereumBridge");
    ethBridge = await EthereumBridge.deploy(await badBunnzEth.getAddress());
    await ethBridge.waitForDeployment();

    // Deploy MegaETH Bridge
    const MegaEthBridge = await ethers.getContractFactory("MegaEthBridge");
    megaBridge = await MegaEthBridge.deploy(await badBunnzMega.getAddress());
    await megaBridge.waitForDeployment();

    // Link bridges
    await ethBridge.setMegaEthBridge(await megaBridge.getAddress());
    await megaBridge.setEthereumBridge(await ethBridge.getAddress());

    // Set bridge addresses on NFT contracts
    await badBunnzEth.setBridgeAddress(await ethBridge.getAddress());
    await badBunnzMega.setBridgeAddress(await megaBridge.getAddress());
  });

  describe("Full Bridge Flow: Ethereum → MegaETH", function () {
    it("Should bridge a Bad_Bunnz NFT from Ethereum to MegaETH", async function () {
      const tokenId = 1;

      // 1. Mint NFT on Ethereum using airdrop
      const recipients = [user1.address];
      const tokenIds = [[tokenId]];
      await badBunnzEth.airdrop(recipients, tokenIds);

      expect(await badBunnzEth.ownerOf(tokenId)).to.equal(user1.address);

      // 2. User approves bridge
      await badBunnzEth.connect(user1).approve(await ethBridge.getAddress(), tokenId);

      // 3. Lock NFT on Ethereum bridge
      const lockTx = await ethBridge.connect(user1).lockNFT(tokenId, user1.address);
      const lockReceipt = await lockTx.wait();
      const lockBlockNumber = lockReceipt.blockNumber;

      expect(await badBunnzEth.ownerOf(tokenId)).to.equal(await ethBridge.getAddress());
      expect(await ethBridge.lockedTokens(tokenId)).to.be.true;

      // 4. Get lock event data
      const lockEvent = lockReceipt.logs.find(
        (log) => {
          try {
            const parsed = ethBridge.interface.parseLog(log);
            return parsed && parsed.name === "NFTLocked";
          } catch {
            return false;
          }
        }
      );
      
      expect(lockEvent).to.not.be.undefined;
      const parsedLockEvent = ethBridge.interface.parseLog(lockEvent);
      const lockHash = parsedLockEvent.args.lockHash;

      // 5. Create Merkle tree and proof
      const leaf = ethers.solidityPackedKeccak256(
        ["uint256", "address", "bytes32", "uint256"],
        [tokenId, user1.address, lockHash, lockBlockNumber]
      );
      
      const tree = new MerkleTree([leaf], keccak256, { sortPairs: true });
      const root = tree.getHexRoot();
      const proof = tree.getHexProof(leaf);

      // 6. Set block root on MegaETH bridge
      const locks = [
        buildLockStruct(tokenId, user1.address, user1.address, lockBlockNumber, lockHash),
      ];
      await megaBridge.setBlockRoot(lockBlockNumber, root, locks.length, locks);

      // 7. Unlock (mint) on MegaETH
      await megaBridge.unlockNFTWithProof(
        tokenId,
        user1.address,
        lockHash,
        lockBlockNumber,
        proof
      );

      // 8. Verify NFT was minted on MegaETH
      expect(await badBunnzMega.ownerOf(tokenId)).to.equal(user1.address);
    });

    it("Should bridge multiple Bad_Bunnz NFTs in batch", async function () {
      const tokenIds = [1, 2, 3];

      // 1. Mint NFTs on Ethereum
      const recipients = [user1.address, user1.address, user1.address];
      const tokenIdArrays = [[tokenIds[0]], [tokenIds[1]], [tokenIds[2]]];
      await badBunnzEth.airdrop(recipients, tokenIdArrays);

      // 2. Approve and lock in batch
      for (const tokenId of tokenIds) {
        await badBunnzEth.connect(user1).approve(await ethBridge.getAddress(), tokenId);
      }

      const lockTx = await ethBridge.connect(user1).batchLockNFT(tokenIds, user1.address);
      const lockReceipt = await lockTx.wait();
      const lockBlockNumber = lockReceipt.blockNumber;

      // 3. Get all lock events
      const lockEvents = lockReceipt.logs
        .map((log) => {
          try {
            return ethBridge.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .filter((parsed) => parsed && parsed.name === "NFTLocked");

      expect(lockEvents.length).to.equal(tokenIds.length);

      // 4. Create Merkle tree with all leaves
      const lockHashes = lockEvents.map((e) => e.args.lockHash);
      const leaves = lockHashes.map((lockHash, i) =>
        ethers.solidityPackedKeccak256(
          ["uint256", "address", "bytes32", "uint256"],
          [tokenIds[i], user1.address, lockHash, lockBlockNumber]
        )
      );

      const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });
      const root = tree.getHexRoot();

      // 5. Set block root and unlock in batch
      const locks = lockHashes.map((lockHash, i) =>
        buildLockStruct(tokenIds[i], user1.address, user1.address, lockBlockNumber, lockHash)
      );
      await megaBridge.setBlockRoot(lockBlockNumber, root, locks.length, locks);
      const proofs = leaves.map((leaf) => tree.getHexProof(leaf));

      await megaBridge.batchUnlockNFTWithProof(
        tokenIds,
        [user1.address, user1.address, user1.address],
        lockHashes,
        [lockBlockNumber, lockBlockNumber, lockBlockNumber],
        proofs
      );

      // 6. Verify all NFTs were minted on MegaETH
      for (const tokenId of tokenIds) {
        expect(await badBunnzMega.ownerOf(tokenId)).to.equal(user1.address);
      }
    });
  });

  describe("Full Bridge Flow: MegaETH → Ethereum", function () {
    it("Should bridge a Bad_Bunnz NFT back from MegaETH to Ethereum", async function () {
      const tokenId = 1;

      // 1. Setup: First bridge from ETH to MegaETH
      const recipients = [user1.address];
      const tokenIdArrays = [[tokenId]];
      await badBunnzEth.airdrop(recipients, tokenIdArrays);
      await badBunnzEth.connect(user1).approve(await ethBridge.getAddress(), tokenId);
      
      const lockTx1 = await ethBridge.connect(user1).lockNFT(tokenId, user1.address);
      const lockReceipt1 = await lockTx1.wait();
      const lockBlockNumber1 = lockReceipt1.blockNumber;
      
      const lockEvent1 = lockReceipt1.logs.find(
        (log) => {
          try {
            const parsed = ethBridge.interface.parseLog(log);
            return parsed && parsed.name === "NFTLocked";
          } catch {
            return false;
          }
        }
      );
      const parsedLockEvent1 = ethBridge.interface.parseLog(lockEvent1);
      const lockHash1 = parsedLockEvent1.args.lockHash;
      
      const leaf1 = ethers.solidityPackedKeccak256(
        ["uint256", "address", "bytes32", "uint256"],
        [tokenId, user1.address, lockHash1, lockBlockNumber1]
      );
      const tree1 = new MerkleTree([leaf1], keccak256, { sortPairs: true });
      const locksStage1 = [
        buildLockStruct(tokenId, user1.address, user1.address, lockBlockNumber1, lockHash1),
      ];
      await megaBridge.setBlockRoot(
        lockBlockNumber1,
        tree1.getHexRoot(),
        locksStage1.length,
        locksStage1
      );
      await megaBridge.unlockNFTWithProof(
        tokenId,
        user1.address,
        lockHash1,
        lockBlockNumber1,
        tree1.getHexProof(leaf1)
      );

      // Token is now on MegaETH, locked on Ethereum
      expect(await badBunnzMega.ownerOf(tokenId)).to.equal(user1.address);
      expect(await ethBridge.lockedTokens(tokenId)).to.be.true;

      // 2. Lock NFT on MegaETH bridge
      await badBunnzMega.connect(user1).approve(await megaBridge.getAddress(), tokenId);
      const lockTx2 = await megaBridge.connect(user1).lockNFTForEthereum(tokenId, user1.address);
      const lockReceipt2 = await lockTx2.wait();
      const lockBlockNumber2 = lockReceipt2.blockNumber;

      // 3. Get lock event from MegaETH
      const lockEvent2 = lockReceipt2.logs.find(
        (log) => {
          try {
            const parsed = megaBridge.interface.parseLog(log);
            return parsed && parsed.name === "NFTLocked";
          } catch {
            return false;
          }
        }
      );
      const parsedLockEvent2 = megaBridge.interface.parseLog(lockEvent2);
      const lockHash2 = parsedLockEvent2.args.lockHash;

      // 4. Create Merkle proof for MegaETH lock
      const leaf2 = ethers.solidityPackedKeccak256(
        ["uint256", "address", "bytes32", "uint256"],
        [tokenId, user1.address, lockHash2, lockBlockNumber2]
      );
      const tree2 = new MerkleTree([leaf2], keccak256, { sortPairs: true });
      const root2 = tree2.getHexRoot();
      const proof2 = tree2.getHexProof(leaf2);

      // 5. Set block root on Ethereum bridge
      const ethLocks = [
        buildLockStruct(tokenId, user1.address, user1.address, lockBlockNumber2, lockHash2),
      ];
      await ethBridge.setMegaEthBlockRoot(
        lockBlockNumber2,
        root2,
        ethLocks.length,
        ethLocks
      );

      // 6. Unlock on Ethereum
      await ethBridge.unlockNFTWithProof(
        tokenId,
        user1.address,
        lockHash2,
        lockBlockNumber2,
        proof2
      );

      // 7. Verify NFT was unlocked on Ethereum
      expect(await badBunnzEth.ownerOf(tokenId)).to.equal(user1.address);
      expect(await ethBridge.lockedTokens(tokenId)).to.be.false;
    });
  });

  describe("Edge Cases and Security", function () {
    it("Should prevent double unlock", async function () {
      const tokenId = 1;

      // Bridge to MegaETH
      const recipients = [user1.address];
      const tokenIdArrays = [[tokenId]];
      await badBunnzEth.airdrop(recipients, tokenIdArrays);
      await badBunnzEth.connect(user1).approve(await ethBridge.getAddress(), tokenId);
      
      const lockTx = await ethBridge.connect(user1).lockNFT(tokenId, user1.address);
      const lockReceipt = await lockTx.wait();
      const lockBlockNumber = lockReceipt.blockNumber;
      
      const lockEvent = lockReceipt.logs.find(
        (log) => {
          try {
            const parsed = ethBridge.interface.parseLog(log);
            return parsed && parsed.name === "NFTLocked";
          } catch {
            return false;
          }
        }
      );
      const parsedLockEvent = ethBridge.interface.parseLog(lockEvent);
      const lockHash = parsedLockEvent.args.lockHash;
      
      const leaf = ethers.solidityPackedKeccak256(
        ["uint256", "address", "bytes32", "uint256"],
        [tokenId, user1.address, lockHash, lockBlockNumber]
      );
      const tree = new MerkleTree([leaf], keccak256, { sortPairs: true });
      const locksSingle = [
        buildLockStruct(tokenId, user1.address, user1.address, lockBlockNumber, lockHash),
      ];
      await megaBridge.setBlockRoot(
        lockBlockNumber,
        tree.getHexRoot(),
        locksSingle.length,
        locksSingle
      );
      
      // First unlock should succeed
      await megaBridge.unlockNFTWithProof(
        tokenId,
        user1.address,
        lockHash,
        lockBlockNumber,
        tree.getHexProof(leaf)
      );

      // Second unlock should fail
      await expect(
        megaBridge.unlockNFTWithProof(
          tokenId,
          user1.address,
          lockHash,
          lockBlockNumber,
          tree.getHexProof(leaf)
        )
      ).to.be.revertedWith("Lock already processed");
    });

    it("Should only allow bridge to mint", async function () {
      const tokenId = 999;

      // Try to mint without being bridge
      await expect(
        badBunnzMega.bridgeMint(user1.address, tokenId)
      ).to.be.revertedWith("Only bridge can call");

      // Bridge should be able to mint (using impersonation)
      const bridgeAddress = await megaBridge.getAddress();
      await ethers.provider.send("hardhat_impersonateAccount", [bridgeAddress]);
      await ethers.provider.send("hardhat_setBalance", [
        bridgeAddress,
        "0x21E19E0C9BAB2400000", // 4,000 ETH
      ]);
      const bridgeSigner = await ethers.getSigner(bridgeAddress);
      await badBunnzMega.connect(bridgeSigner).bridgeMint(user1.address, tokenId);
      expect(await badBunnzMega.ownerOf(tokenId)).to.equal(user1.address);
    });

    it("Should reject invalid merkle proof", async function () {
      const tokenId = 1;

      const recipients = [user1.address];
      const tokenIdArrays = [[tokenId]];
      await badBunnzEth.airdrop(recipients, tokenIdArrays);
      await badBunnzEth.connect(user1).approve(await ethBridge.getAddress(), tokenId);
      
      const lockTx = await ethBridge.connect(user1).lockNFT(tokenId, user1.address);
      const lockReceipt = await lockTx.wait();
      const lockBlockNumber = lockReceipt.blockNumber;
      
      const lockEvent = lockReceipt.logs.find(
        (log) => {
          try {
            const parsed = ethBridge.interface.parseLog(log);
            return parsed && parsed.name === "NFTLocked";
          } catch {
            return false;
          }
        }
      );
      const parsedLockEvent = ethBridge.interface.parseLog(lockEvent);
      const lockHash = parsedLockEvent.args.lockHash;
      
      // Set a different root
      const wrongLeaf = ethers.solidityPackedKeccak256(
        ["uint256", "address", "bytes32", "uint256"],
        [999, user1.address, lockHash, lockBlockNumber]
      );
      const wrongTree = new MerkleTree([wrongLeaf], keccak256, { sortPairs: true });
      const locksSingle = [
        buildLockStruct(tokenId, user1.address, user1.address, lockBlockNumber, lockHash),
      ];
      await megaBridge.setBlockRoot(
        lockBlockNumber,
        wrongTree.getHexRoot(),
        locksSingle.length,
        locksSingle
      );

      // Try to unlock with wrong proof
      await expect(
        megaBridge.unlockNFTWithProof(
          tokenId,
          user1.address,
          lockHash,
          lockBlockNumber,
          wrongTree.getHexProof(wrongLeaf)
        )
      ).to.be.revertedWith("Invalid merkle proof");
    });
  });
});

