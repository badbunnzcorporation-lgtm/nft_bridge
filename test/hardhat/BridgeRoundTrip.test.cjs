const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');
const { anyValue } = require('@nomicfoundation/hardhat-chai-matchers/withArgs');

const buildLockStruct = (tokenId, owner, recipient, blockNumber, lockHash) => ({
  tokenId,
  owner,
  recipient,
  blockNumber,
  lockHash,
});

describe('Bridge Round-Trip Tests', function () {
  // Test fixture for deployment
  async function deployBridgeFixture() {
    const [owner, alice, bob, charlie] = await ethers.getSigners();

    // Deploy proxy NFTs (SimpleNFT implements required bridge interface)
    const SimpleNFT = await ethers.getContractFactory('SimpleNFT');
    const ethNFT = await SimpleNFT.deploy('Bad Bunnz', 'BUNNZ');
    await ethNFT.waitForDeployment();

    const megaNFT = await SimpleNFT.deploy('Bad Bunnz', 'BUNNZ');
    await megaNFT.waitForDeployment();

    // Deploy bridges
    const EthereumBridge = await ethers.getContractFactory('EthereumBridge');
    const ethBridge = await EthereumBridge.deploy(await ethNFT.getAddress());
    await ethBridge.waitForDeployment();

    const MegaEthBridge = await ethers.getContractFactory('MegaEthBridge');
    const megaBridge = await MegaEthBridge.deploy(await megaNFT.getAddress());
    await megaBridge.waitForDeployment();

    // Configure bridges
    await megaNFT.setBridgeAddress(await megaBridge.getAddress());
    await ethBridge.setMegaEthBridge(await megaBridge.getAddress());
    await megaBridge.setEthereumBridge(await ethBridge.getAddress());

    // Mint test NFTs to Alice
    await ethNFT.mint(alice.address, 1);
    await ethNFT.mint(alice.address, 2);
    await ethNFT.mint(alice.address, 3);

    return { ethNFT, megaNFT, ethBridge, megaBridge, owner, alice, bob, charlie };
  }

  // Helper function to bridge from ETH to MegaETH
  async function bridgeToMegaETH(ethNFT, ethBridge, megaBridge, from, to, tokenId) {
    // Lock on Ethereum
    await ethNFT.connect(from).approve(await ethBridge.getAddress(), tokenId);
    const lockTx = await ethBridge.connect(from).lockNFT(tokenId, to.address);
    const lockReceipt = await lockTx.wait();
    const lockBlock = lockReceipt.blockNumber;

    // Get lock event
    const lockEvent = lockReceipt.logs.find(
      (log) => log.fragment && log.fragment.name === 'NFTLocked'
    );
    const lockHash = lockEvent.args.lockHash;

    // Create merkle proof (simplified for testing)
    const leaf = ethers.solidityPackedKeccak256(
      ['uint256', 'address', 'bytes32', 'uint256'],
      [tokenId, to.address, lockHash, lockBlock]
    );

    // Set block root
    const locks = [buildLockStruct(tokenId, from.address, to.address, lockBlock, lockHash)];
    await megaBridge.setBlockRoot(lockBlock, leaf, locks.length, locks);

    // Unlock on MegaETH
    await megaBridge.unlockNFTWithProof(tokenId, to.address, lockHash, lockBlock, []);

    return { lockHash, lockBlock };
  }

  // Helper function to bridge from MegaETH to ETH
  async function bridgeToEthereum(megaNFT, megaBridge, ethBridge, from, to, tokenId) {
    // Lock on MegaETH
    await megaNFT.connect(from).approve(await megaBridge.getAddress(), tokenId);
    const lockTx = await megaBridge.connect(from).lockNFTForEthereum(tokenId, to.address);
    const lockReceipt = await lockTx.wait();
    const lockBlock = lockReceipt.blockNumber;

    // Get lock event
    const lockEvent = lockReceipt.logs.find(
      (log) => log.fragment && log.fragment.name === 'NFTLocked'
    );
    const lockHash = lockEvent.args.lockHash;

    // Create merkle proof
    const leaf = ethers.solidityPackedKeccak256(
      ['uint256', 'address', 'bytes32', 'uint256'],
      [tokenId, to.address, lockHash, lockBlock]
    );

    // Set block root on Ethereum
    const locks = [buildLockStruct(tokenId, from.address, to.address, lockBlock, lockHash)];
    await ethBridge.setMegaEthBlockRoot(lockBlock, leaf, locks.length, locks);

    // Unlock on Ethereum
    await ethBridge.unlockNFTWithProof(tokenId, to.address, lockHash, lockBlock, []);

    return { lockHash, lockBlock };
  }

  describe('Flow 1: ETH → MegaETH (First Time)', function () {
    it('Should lock NFT on Ethereum successfully', async function () {
      const { ethNFT, ethBridge, alice, bob } = await loadFixture(deployBridgeFixture);

      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 1);
      await expect(ethBridge.connect(alice).lockNFT(1, bob.address))
        .to.emit(ethBridge, 'NFTLocked')
        .withArgs(1, alice.address, bob.address, anyValue, anyValue);

      expect(await ethNFT.ownerOf(1)).to.equal(await ethBridge.getAddress());
      expect(await ethBridge.lockedTokens(1)).to.be.true;
    });

    it('Should mint NFT on MegaETH for first time', async function () {
      const { ethNFT, megaNFT, ethBridge, megaBridge, alice, bob } = await loadFixture(
        deployBridgeFixture
      );

      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, alice, bob, 1);

      expect(await megaNFT.ownerOf(1)).to.equal(bob.address);
      expect(await megaBridge.activeOnMegaETH(1)).to.be.true;
      expect(await megaBridge.lockedTokens(1)).to.be.false;
    });

    it('Should prevent double unlock with same lock hash', async function () {
      const { ethNFT, ethBridge, megaBridge, alice, bob } = await loadFixture(
        deployBridgeFixture
      );

      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 1);
      const lockTx = await ethBridge.connect(alice).lockNFT(1, bob.address);
      const lockReceipt = await lockTx.wait();
      const lockBlock = lockReceipt.blockNumber;

      const lockEvent = lockReceipt.logs.find(
        (log) => log.fragment && log.fragment.name === 'NFTLocked'
      );
      const lockHash = lockEvent.args.lockHash;

      const leaf = ethers.solidityPackedKeccak256(
        ['uint256', 'address', 'bytes32', 'uint256'],
        [1, bob.address, lockHash, lockBlock]
      );

      const locks = [buildLockStruct(1, alice.address, bob.address, lockBlock, lockHash)];
      await megaBridge.setBlockRoot(lockBlock, leaf, locks.length, locks);
      await megaBridge.unlockNFTWithProof(1, bob.address, lockHash, lockBlock, []);

      await expect(
        megaBridge.unlockNFTWithProof(1, bob.address, lockHash, lockBlock, [])
      ).to.be.revertedWith('Lock already processed');
    });
  });

  describe('Flow 2: MegaETH → ETH (Bridge Back)', function () {
    it('Should lock NFT on MegaETH successfully', async function () {
      const { ethNFT, megaNFT, ethBridge, megaBridge, alice, bob, charlie } =
        await loadFixture(deployBridgeFixture);

      // First bridge to MegaETH
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, alice, bob, 1);

      // Lock on MegaETH
      await megaNFT.connect(bob).approve(await megaBridge.getAddress(), 1);
      await expect(megaBridge.connect(bob).lockNFTForEthereum(1, charlie.address))
        .to.emit(megaBridge, 'NFTLocked')
        .withArgs(1, bob.address, charlie.address, anyValue, anyValue);

      expect(await megaNFT.ownerOf(1)).to.equal(await megaBridge.getAddress());
      expect(await megaBridge.lockedTokens(1)).to.be.true;
    });

    it('Should unlock original NFT on Ethereum', async function () {
      const { ethNFT, megaNFT, ethBridge, megaBridge, alice, bob, charlie } =
        await loadFixture(deployBridgeFixture);

      // Bridge to MegaETH
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, alice, bob, 1);

      // Bridge back to Ethereum
      await bridgeToEthereum(megaNFT, megaBridge, ethBridge, bob, charlie, 1);

      expect(await ethNFT.ownerOf(1)).to.equal(charlie.address);
      expect(await ethBridge.lockedTokens(1)).to.be.false;
    });

    it('Should prevent locking token that is not active on MegaETH', async function () {
      const { megaBridge, alice, bob } = await loadFixture(deployBridgeFixture);

      await expect(
        megaBridge.connect(alice).lockNFTForEthereum(1, bob.address)
      ).to.be.revertedWith('Token not active on MegaETH');
    });
  });

  describe('Flow 3: ETH → MegaETH (Round-Trip)', function () {
    it('Should unlock existing token instead of minting on round-trip', async function () {
      const { ethNFT, megaNFT, ethBridge, megaBridge, alice, bob, charlie } =
        await loadFixture(deployBridgeFixture);

      // Step 1: Bridge to MegaETH (first time - mints)
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, alice, bob, 1);
      expect(await megaNFT.ownerOf(1)).to.equal(bob.address);
      expect(await megaBridge.activeOnMegaETH(1)).to.be.true;

      // Step 2: Bridge back to Ethereum
      await bridgeToEthereum(megaNFT, megaBridge, ethBridge, bob, charlie, 1);
      expect(await ethNFT.ownerOf(1)).to.equal(charlie.address);
      expect(await megaBridge.lockedTokens(1)).to.be.true;

      // Step 3: Bridge to MegaETH again (should unlock, not mint)
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, charlie, alice, 1);
      expect(await megaNFT.ownerOf(1)).to.equal(alice.address);
      expect(await megaBridge.activeOnMegaETH(1)).to.be.true;
      expect(await megaBridge.lockedTokens(1)).to.be.false;
    });

    it('Should handle multiple round-trips correctly', async function () {
      const { ethNFT, megaNFT, ethBridge, megaBridge, alice, bob, charlie } =
        await loadFixture(deployBridgeFixture);

      // Round-trip 1: ETH → Mega → ETH
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, alice, bob, 1);
      await bridgeToEthereum(megaNFT, megaBridge, ethBridge, bob, charlie, 1);

      // Round-trip 2: ETH → Mega → ETH
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, charlie, alice, 1);
      await bridgeToEthereum(megaNFT, megaBridge, ethBridge, alice, bob, 1);

      // Round-trip 3: ETH → Mega
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, bob, charlie, 1);

      // Verify final state
      expect(await megaNFT.ownerOf(1)).to.equal(charlie.address);
      expect(await megaBridge.activeOnMegaETH(1)).to.be.true;
      expect(await megaBridge.lockedTokens(1)).to.be.false;
    });
  });

  describe('Batch Operations', function () {
    it('Should batch lock multiple NFTs on Ethereum', async function () {
      const { ethNFT, ethBridge, alice, bob } = await loadFixture(deployBridgeFixture);

      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 1);
      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 2);
      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 3);

      await ethBridge.connect(alice).batchLockNFT([1, 2, 3], bob.address);

      expect(await ethBridge.lockedTokens(1)).to.be.true;
      expect(await ethBridge.lockedTokens(2)).to.be.true;
      expect(await ethBridge.lockedTokens(3)).to.be.true;
    });

    it('Should batch unlock multiple NFTs on MegaETH', async function () {
      const { ethNFT, ethBridge, megaBridge, alice, bob } = await loadFixture(
        deployBridgeFixture
      );

      // Lock multiple tokens
      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 1);
      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 2);
      const lockTx = await ethBridge.connect(alice).batchLockNFT([1, 2], bob.address);
      const lockReceipt = await lockTx.wait();
      const lockBlock = lockReceipt.blockNumber;

      // Get lock events
      const lockEvents = lockReceipt.logs.filter(
        (log) => log.fragment && log.fragment.name === 'NFTLocked'
      );

      const lockHashes = lockEvents.map((e) => e.args.lockHash);
      const tokenIds = [1, 2];
      const recipients = [bob.address, bob.address];
      const blockNumbers = [lockBlock, lockBlock];

      // Build merkle data for two leaves
      const leaves = tokenIds.map((tokenId, index) =>
        ethers.solidityPackedKeccak256(
          ['uint256', 'address', 'bytes32', 'uint256'],
          [tokenId, recipients[index], lockHashes[index], lockBlock]
        )
      );
      const root =
        leaves[0] < leaves[1]
          ? ethers.keccak256(ethers.solidityPacked(['bytes32', 'bytes32'], [leaves[0], leaves[1]]))
          : ethers.keccak256(ethers.solidityPacked(['bytes32', 'bytes32'], [leaves[1], leaves[0]]));
      const proofs = [
        [leaves[1]],
        [leaves[0]],
      ];

      const locks = tokenIds.map((tokenId, index) =>
        buildLockStruct(tokenId, alice.address, recipients[index], lockBlock, lockHashes[index])
      );
      await megaBridge.setBlockRoot(lockBlock, root, locks.length, locks);

      // Batch unlock
      await megaBridge.batchUnlockNFTWithProof(tokenIds, recipients, lockHashes, blockNumbers, proofs);

      expect(await megaBridge.activeOnMegaETH(1)).to.be.true;
      expect(await megaBridge.activeOnMegaETH(2)).to.be.true;
    });
  });

  describe('Edge Cases', function () {
    it('Should prevent locking already locked token', async function () {
      const { ethNFT, ethBridge, alice, bob } = await loadFixture(deployBridgeFixture);

      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 1);
      await ethBridge.connect(alice).lockNFT(1, bob.address);

      await expect(ethBridge.connect(alice).lockNFT(1, bob.address)).to.be.revertedWith(
        'Token already locked'
      );
    });

    it('Should prevent unlocking without block root', async function () {
      const { ethNFT, ethBridge, megaBridge, alice, bob } = await loadFixture(
        deployBridgeFixture
      );

      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 1);
      const lockTx = await ethBridge.connect(alice).lockNFT(1, bob.address);
      const lockReceipt = await lockTx.wait();

      const lockEvent = lockReceipt.logs.find(
        (log) => log.fragment && log.fragment.name === 'NFTLocked'
      );
      const lockHash = lockEvent.args.lockHash;

      await expect(
        megaBridge.unlockNFTWithProof(1, bob.address, lockHash, lockReceipt.blockNumber, [])
      ).to.be.revertedWith('Block root not set');
    });

    it('Should prevent locking to zero address', async function () {
      const { ethNFT, ethBridge, alice } = await loadFixture(deployBridgeFixture);

      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 1);
      await expect(
        ethBridge.connect(alice).lockNFT(1, ethers.ZeroAddress)
      ).to.be.revertedWith('Invalid recipient');
    });

    it('Should prevent unlocking with invalid proof', async function () {
      const { ethNFT, ethBridge, megaBridge, alice, bob } = await loadFixture(
        deployBridgeFixture
      );

      await ethNFT.connect(alice).approve(await ethBridge.getAddress(), 1);
      const lockTx = await ethBridge.connect(alice).lockNFT(1, bob.address);
      const lockReceipt = await lockTx.wait();
      const lockBlock = lockReceipt.blockNumber;

      const lockEvent = lockReceipt.logs.find(
        (log) => log.fragment && log.fragment.name === 'NFTLocked'
      );
      const lockHash = lockEvent.args.lockHash;

      // Set wrong block root
      const locks = [buildLockStruct(1, alice.address, bob.address, lockBlock, lockHash)];
      await megaBridge.setBlockRoot(lockBlock, ethers.id('wrong'), locks.length, locks);

      await expect(
        megaBridge.unlockNFTWithProof(1, bob.address, lockHash, lockBlock, [])
      ).to.be.revertedWith('Invalid merkle proof');
    });
  });

  describe('State Verification', function () {
    it('Should track activeOnMegaETH correctly through full cycle', async function () {
      const { ethNFT, megaNFT, ethBridge, megaBridge, alice, bob } = await loadFixture(
        deployBridgeFixture
      );

      // Initially not active
      expect(await megaBridge.activeOnMegaETH(1)).to.be.false;

      // After first bridge - active
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, alice, bob, 1);
      expect(await megaBridge.activeOnMegaETH(1)).to.be.true;

      // After bridge back - still active
      await bridgeToEthereum(megaNFT, megaBridge, ethBridge, bob, alice, 1);
      expect(await megaBridge.activeOnMegaETH(1)).to.be.true;

      // After round-trip - still active
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, alice, bob, 1);
      expect(await megaBridge.activeOnMegaETH(1)).to.be.true;
    });

    it('Should track lockedTokens correctly on MegaETH', async function () {
      const { ethNFT, megaNFT, ethBridge, megaBridge, alice, bob } = await loadFixture(
        deployBridgeFixture
      );

      // Initially not locked
      expect(await megaBridge.lockedTokens(1)).to.be.false;

      // After bridge to MegaETH - not locked
      await bridgeToMegaETH(ethNFT, ethBridge, megaBridge, alice, bob, 1);
      expect(await megaBridge.lockedTokens(1)).to.be.false;

      // After locking for Ethereum - locked
      await megaNFT.connect(bob).approve(await megaBridge.getAddress(), 1);
      await megaBridge.connect(bob).lockNFTForEthereum(1, alice.address);
      expect(await megaBridge.lockedTokens(1)).to.be.true;
    });
  });
});
