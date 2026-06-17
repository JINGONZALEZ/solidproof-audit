const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-network-helpers");

describe("PreselloVault — Governance", function () {
  async function deployVaultFixture() {
    const [deployer, signer1, signer2, signer3, backend, safeAddr, buyer, outsider, newSigner] =
      await ethers.getSigners();

    const signerAddrs = [signer1.address, signer2.address, signer3.address];
    const dailyCap = ethers.parseEther("100000");
    const largeThreshold = ethers.parseEther("50000");
    const minDailyCap = ethers.parseEther("1000");
    const minLargeThreshold = ethers.parseEther("500");
    const maxDailyCap = ethers.parseEther("10000000");
    const maxLargeThreshold = ethers.parseEther("5000000");

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const token = await MockERC20.deploy("Test Token", "TST", 18);

    const Vault = await ethers.getContractFactory("PreselloVault");
    const vault = await Vault.deploy(
      signerAddrs, backend.address, safeAddr.address,
      dailyCap, largeThreshold, minDailyCap, minLargeThreshold,
      maxDailyCap, maxLargeThreshold
    );

    // Allowlist token
    await vault.connect(signer1).allowToken(await token.getAddress());

    const mintAmount = ethers.parseEther("1000000");
    await token.mint(signer1.address, mintAmount);
    await token.connect(signer1).approve(await vault.getAddress(), mintAmount);

    return {
      vault, token, deployer,
      signer1, signer2, signer3, backend, safeAddr, buyer, outsider, newSigner,
      dailyCap, largeThreshold, minDailyCap, minLargeThreshold,
    };
  }

  async function depositFrom(vault, token, signer, amount) {
    return vault.connect(signer).deposit(await token.getAddress(), amount);
  }

  async function getProposalId(vault, tx) {
    const receipt = await tx.wait();
    const log = receipt.logs.find(
      (l) => vault.interface.parseLog({ topics: l.topics, data: l.data })?.name === "ProposalCreated"
    );
    return vault.interface.parseLog({ topics: log.topics, data: log.data }).args[0];
  }

  // ===============================================================
  //                 CHANGE BACKEND ADDRESS
  // ===============================================================

  describe("Change Backend Address", function () {
    it("should change backend with 2-of-3 approval + 24h timelock", async function () {
      const { vault, signer1, signer2, outsider } = await loadFixture(deployVaultFixture);
      const tx = await vault.connect(signer1).proposeChangeBackend(outsider.address);
      const pid = await getProposalId(vault, tx);
      expect(await vault.backendAddress()).to.not.equal(outsider.address);
      // Approval sets the timelock, does not execute immediately
      await vault.connect(signer2).approveChangeBackend(pid);
      expect(await vault.backendAddress()).to.not.equal(outsider.address);
      // Advance past 24h timelock
      await ethers.provider.send("evm_increaseTime", [24 * 3600 + 1]);
      await ethers.provider.send("evm_mine");
      // Now execute
      await vault.connect(signer1).executeChangeBackend(pid);
      expect(await vault.backendAddress()).to.equal(outsider.address);
    });

    it("should prevent double-approval by same signer", async function () {
      const { vault, signer1, outsider } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).proposeChangeBackend(outsider.address);
      await expect(vault.connect(signer1).approveChangeBackend(0))
        .to.be.revertedWith("Vault: already approved");
    });

    it("should reject wrong proposal type on approve", async function () {
      const { vault, signer1, signer2 } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).pause();
      await vault.connect(signer1).proposeUnpause();
      // Try to approve an UNPAUSE proposal as a CHANGE_BACKEND
      await expect(vault.connect(signer2).approveChangeBackend(0))
        .to.be.revertedWith("Vault: wrong proposal type");
    });

    it("should reject expired proposals", async function () {
      const { vault, signer1, signer2, outsider } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).proposeChangeBackend(outsider.address);
      await time.increase(7 * 24 * 60 * 60 + 1);
      await expect(vault.connect(signer2).approveChangeBackend(0))
        .to.be.revertedWith("Vault: proposal expired");
    });
  });

  // ===============================================================
  //                 SIGNER ROTATION
  // ===============================================================

  describe("Signer Rotation", function () {
    it("should rotate a signer with 2-of-3 approval + 7-day delay", async function () {
      const { vault, signer1, signer2, newSigner } = await loadFixture(deployVaultFixture);
      const tx = await vault.connect(signer1).proposeRotateSigner(signer1.address, newSigner.address);
      const pid = await getProposalId(vault, tx);
      await vault.connect(signer2).approveRotateSigner(pid);

      // Cannot execute before 7 days
      await expect(vault.connect(signer2).executeRotateSigner(pid))
        .to.be.revertedWith("Vault: rotation delay not elapsed");

      await time.increase(7 * 24 * 60 * 60);
      await expect(vault.connect(signer2).executeRotateSigner(pid))
        .to.emit(vault, "SignerRotated")
        .withArgs(signer1.address, newSigner.address);

      // Old signer is no longer a signer
      await expect(vault.connect(signer1).pause())
        .to.be.revertedWith("Vault: caller is not a signer");
      // New signer works
      await expect(vault.connect(newSigner).pause()).to.not.be.reverted;
    });

    it("should reject rotating to an existing signer", async function () {
      const { vault, signer1, signer2 } = await loadFixture(deployVaultFixture);
      await expect(vault.connect(signer1).proposeRotateSigner(signer1.address, signer2.address))
        .to.be.revertedWith("Vault: already a signer");
    });

    it("should reject rotating to the backend address", async function () {
      const { vault, signer1, backend } = await loadFixture(deployVaultFixture);
      await expect(vault.connect(signer1).proposeRotateSigner(signer1.address, backend.address))
        .to.be.revertedWith("Vault: new signer == backend");
    });

    it("should reject rotating a non-signer", async function () {
      const { vault, signer1, outsider, newSigner } = await loadFixture(deployVaultFixture);
      await expect(vault.connect(signer1).proposeRotateSigner(outsider.address, newSigner.address))
        .to.be.revertedWith("Vault: not a current signer");
    });
  });

  // ===============================================================
  //                 RESCUE TOKEN
  // ===============================================================

  describe("Rescue Token", function () {
    it("should rescue tokens to safe address with 2-of-3 + 24h timelock", async function () {
      const { vault, token, signer1, signer2, safeAddr } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("5000"));

      const tx = await vault.connect(signer1).proposeRescueToken(await token.getAddress());
      const pid = await getProposalId(vault, tx);

      // Approve creates a 24h timelock (not instant)
      await expect(vault.connect(signer2).approveRescueToken(pid))
        .to.emit(vault, "TokenRescued");

      // Tokens are NOT yet transferred — must wait 24h
      expect(await vault.tokenBalance(await token.getAddress())).to.equal(ethers.parseEther("5000"));

      // Execute via emergency withdraw path after 24h
      await time.increase(24 * 60 * 60);
      await vault.connect(signer1).executeEmergencyWithdraw(0);

      expect(await token.balanceOf(safeAddr.address)).to.equal(ethers.parseEther("5000"));
      expect(await vault.tokenBalance(await token.getAddress())).to.equal(0n);
    });

    it("should revert rescue from non-signer", async function () {
      const { vault, token, outsider } = await loadFixture(deployVaultFixture);
      await expect(vault.connect(outsider).proposeRescueToken(await token.getAddress()))
        .to.be.revertedWith("Vault: caller is not a signer");
    });

    it("should revert rescue approval with zero balance", async function () {
      const { vault, token, signer1, signer2 } = await loadFixture(deployVaultFixture);
      const tx = await vault.connect(signer1).proposeRescueToken(await token.getAddress());
      const pid = await getProposalId(vault, tx);
      await expect(vault.connect(signer2).approveRescueToken(pid))
        .to.be.revertedWith("Vault: no balance to rescue");
    });
  });

  // ===============================================================
  //                 CANCEL PROPOSAL
  // ===============================================================

  describe("Cancel Proposal", function () {
    it("should cancel a proposal with 2-of-3 cancel votes", async function () {
      const { vault, signer1, signer2, signer3, outsider } = await loadFixture(deployVaultFixture);
      const tx = await vault.connect(signer1).proposeChangeBackend(outsider.address);
      const pid = await getProposalId(vault, tx);

      // First cancel vote
      await vault.connect(signer2).cancelProposal(pid);
      const p1 = await vault.proposals(pid);
      expect(p1.cancelled).to.be.false; // Not yet cancelled

      // Second cancel vote
      await expect(vault.connect(signer3).cancelProposal(pid))
        .to.emit(vault, "ProposalCancelled");
      const p2 = await vault.proposals(pid);
      expect(p2.cancelled).to.be.true;
    });

    it("should prevent approving a cancelled proposal", async function () {
      const { vault, signer1, signer2, signer3, outsider } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).proposeChangeBackend(outsider.address);
      await vault.connect(signer2).cancelProposal(0);
      await vault.connect(signer3).cancelProposal(0);
      await expect(vault.connect(signer2).approveChangeBackend(0))
        .to.be.revertedWith("Vault: cancelled");
    });

    it("should prevent double cancel vote", async function () {
      const { vault, signer1, signer2, outsider } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).proposeChangeBackend(outsider.address);
      // signer2 hasn't approved, so they CAN cancel
      await vault.connect(signer2).cancelProposal(0);
      await expect(vault.connect(signer2).cancelProposal(0))
        .to.be.revertedWith("Vault: already voted to cancel");
    });
  });

  // ===============================================================
  //                 ONE-PER-TYPE PROPOSALS
  // ===============================================================

  describe("One Active Proposal Per Type", function () {
    it("should reject second proposal of same type while first is active", async function () {
      const { vault, signer1, outsider, buyer } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).proposeChangeBackend(outsider.address);
      await expect(vault.connect(signer1).proposeChangeBackend(buyer.address))
        .to.be.revertedWith("Vault: active proposal exists for this type");
    });

    it("should allow new proposal after previous is executed", async function () {
      const { vault, signer1, signer2, outsider, buyer } = await loadFixture(deployVaultFixture);
      const tx = await vault.connect(signer1).proposeChangeBackend(outsider.address);
      const pid = await getProposalId(vault, tx);
      await vault.connect(signer2).approveChangeBackend(pid);
      // Advance past 24h backend change timelock
      await time.increase(24 * 3600 + 1);
      await vault.connect(signer1).executeChangeBackend(pid);
      // Now executed — new proposal should work
      await expect(vault.connect(signer1).proposeChangeBackend(buyer.address))
        .to.not.be.reverted;
    });

    it("should allow new proposal after previous expires", async function () {
      const { vault, signer1, outsider, buyer } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).proposeChangeBackend(outsider.address);
      // Backend change has extended expiry: PROPOSAL_EXPIRY + CHANGE_BACKEND_TIMELOCK = 7d + 24h
      await time.increase(8 * 24 * 60 * 60 + 1);
      await expect(vault.connect(signer1).proposeChangeBackend(buyer.address))
        .to.not.be.reverted;
    });

    it("should allow new proposal after previous is cancelled", async function () {
      const { vault, signer1, signer2, signer3, outsider, buyer } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).proposeChangeBackend(outsider.address);
      await vault.connect(signer2).cancelProposal(0);
      await vault.connect(signer3).cancelProposal(0);
      await expect(vault.connect(signer1).proposeChangeBackend(buyer.address))
        .to.not.be.reverted;
    });
  });

  // ===============================================================
  //                 CONFIGURATION
  // ===============================================================

  describe("Configuration", function () {
    it("should allow signer to set per-token daily cap", async function () {
      const { vault, token, signer1 } = await loadFixture(deployVaultFixture);
      const newCap = ethers.parseEther("500000");
      await expect(vault.connect(signer1).setDailyCap(await token.getAddress(), newCap))
        .to.emit(vault, "DailyCapUpdated");
      expect(await vault.getDailyCap(await token.getAddress())).to.equal(newCap);
    });

    it("should reject config from non-signer", async function () {
      const { vault, token, outsider } = await loadFixture(deployVaultFixture);
      await expect(
        vault.connect(outsider).setDailyCap(await token.getAddress(), ethers.parseEther("100000"))
      ).to.be.revertedWith("Vault: caller is not a signer");
    });

    it("should reject setting cap below minimum", async function () {
      const { vault, signer1, minDailyCap } = await loadFixture(deployVaultFixture);
      await expect(vault.connect(signer1).setDailyCap(ethers.ZeroAddress, minDailyCap - 1n))
        .to.be.revertedWith("Vault: below minimum cap");
    });

    it("should reject setting threshold below minimum", async function () {
      const { vault, signer1, minLargeThreshold } = await loadFixture(deployVaultFixture);
      await expect(vault.connect(signer1).setLargeThreshold(ethers.ZeroAddress, minLargeThreshold - 1n))
        .to.be.revertedWith("Vault: below minimum threshold");
    });

    it("should reject setting cap above maximum", async function () {
      const { vault, signer1 } = await loadFixture(deployVaultFixture);
      const maxCap = await vault.maxDailyCap();
      await expect(vault.connect(signer1).setDailyCap(ethers.ZeroAddress, maxCap + 1n))
        .to.be.revertedWith("Vault: above maximum cap");
    });

    it("should reject setting cap below token threshold (cross-validation)", async function () {
      const { vault, token, signer1 } = await loadFixture(deployVaultFixture);
      const tokenAddr = await token.getAddress();
      // Default threshold is 50000. Try to set per-token cap to 10000 (below threshold).
      await expect(vault.connect(signer1).setDailyCap(tokenAddr, ethers.parseEther("10000")))
        .to.be.revertedWith("Vault: cap below token threshold");
    });
  });

  // ===============================================================
  //         HIGH-PRIORITY TESTS (from re-audit T-01 to T-04)
  // ===============================================================

  describe("Critical Path Tests", function () {
    it("T-01: executeEmergencyWithdraw should succeed while vault is paused", async function () {
      const { vault, token, signer1, signer2, safeAddr } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("5000"));

      // Propose + approve emergency withdraw
      const tx = await vault.connect(signer1).proposeEmergencyWithdraw(await token.getAddress());
      const pid = await getProposalId(vault, tx);
      await vault.connect(signer2).approveEmergencyWithdraw(pid);

      // Pause the vault
      await vault.connect(signer1).pause();
      expect(await vault.paused()).to.be.true;

      // Advance 72 hours and execute — should work EVEN while paused
      await time.increase(72 * 60 * 60);
      await expect(vault.connect(signer1).executeEmergencyWithdraw(0)).to.not.be.reverted;
      expect(await token.balanceOf(safeAddr.address)).to.equal(ethers.parseEther("5000"));
    });

    it("T-02: rescue token approval should succeed while vault is paused", async function () {
      const { vault, token, signer1, signer2 } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("5000"));

      // Pause the vault
      await vault.connect(signer1).pause();
      expect(await vault.paused()).to.be.true;

      // Propose + approve rescue — should work while paused
      const tx = await vault.connect(signer1).proposeRescueToken(await token.getAddress());
      const pid = await getProposalId(vault, tx);
      await expect(vault.connect(signer2).approveRescueToken(pid))
        .to.emit(vault, "TokenRescued");
    });

    it("T-03: old signer approval should NOT count after signer rotation", async function () {
      const { vault, token, signer1, signer2, signer3, newSigner, outsider } = await loadFixture(deployVaultFixture);

      // Signer1 proposes backend change, auto-approves (count = 1)
      const tx = await vault.connect(signer1).proposeChangeBackend(outsider.address);
      const pid = await getProposalId(vault, tx);
      expect(await vault.getApprovalCount(pid)).to.equal(1n);

      // Now rotate signer1 out
      const rotTx = await vault.connect(signer2).proposeRotateSigner(signer1.address, newSigner.address);
      const rotPid = await getProposalId(vault, rotTx);
      await vault.connect(signer3).approveRotateSigner(rotPid);
      await time.increase(7 * 24 * 60 * 60);
      await vault.connect(signer2).executeRotateSigner(rotPid);

      // Signer1's approval on the backend change should no longer count
      expect(await vault.getApprovalCount(pid)).to.equal(0n);
    });

    it("T-04: failed batch items should NOT consume daily cap", async function () {
      const { vault, token, signer1, backend, buyer, dailyCap } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("200000"));
      const tokenAddr = await token.getAddress();

      // Batch: 1 valid (100 tokens) + 1 to zero address (fails)
      await vault.connect(backend).batchRelease(
        [tokenAddr, tokenAddr],
        [buyer.address, ethers.ZeroAddress],
        [ethers.parseEther("100"), ethers.parseEther("200")]
      );

      // Only 100 should be consumed from daily cap (not 100 + 200)
      const remaining = await vault.remainingDailyCapacity(tokenAddr);
      expect(remaining).to.equal(dailyCap - ethers.parseEther("100"));
    });
  });
});
