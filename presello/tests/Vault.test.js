const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  loadFixture,
  time,
  mine,
} = require("@nomicfoundation/hardhat-network-helpers");

describe("PreselloVault", function () {
  // ---------------------------------------------------------------
  //  Shared fixture — deployed once, snapshot reused per test
  // ---------------------------------------------------------------
  async function deployVaultFixture() {
    const [deployer, signer1, signer2, signer3, backend, safeAddr, buyer, outsider] =
      await ethers.getSigners();

    const signerAddrs = [signer1.address, signer2.address, signer3.address];

    const dailyCap = ethers.parseEther("100000");
    const largeThreshold = ethers.parseEther("50000");
    const minDailyCap = ethers.parseEther("1000");
    const minLargeThreshold = ethers.parseEther("500");
    const maxDailyCap = ethers.parseEther("10000000");
    const maxLargeThreshold = ethers.parseEther("5000000");

    // Deploy mock token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const token = await MockERC20.deploy("Test Token", "TST", 18);

    // Deploy fee-on-transfer mock (2% fee)
    const FeeToken = await ethers.getContractFactory("FeeOnTransferMockERC20");
    const feeToken = await FeeToken.deploy("Fee Token", "FEE", 18, 2);

    // Deploy vault with new 7-param constructor
    const Vault = await ethers.getContractFactory("PreselloVault");
    const vault = await Vault.deploy(
      signerAddrs, backend.address, safeAddr.address,
      dailyCap, largeThreshold, minDailyCap, minLargeThreshold,
      maxDailyCap, maxLargeThreshold
    );

    // Allowlist tokens
    await vault.connect(signer1).allowToken(await token.getAddress());
    await vault.connect(signer1).allowToken(await feeToken.getAddress());

    // Mint and approve standard token
    const mintAmount = ethers.parseEther("1000000");
    await token.mint(signer1.address, mintAmount);
    await token.connect(signer1).approve(await vault.getAddress(), mintAmount);
    await token.mint(deployer.address, mintAmount);
    await token.connect(deployer).approve(await vault.getAddress(), mintAmount);

    // Mint and approve fee token
    await feeToken.mint(signer1.address, mintAmount);
    await feeToken.connect(signer1).approve(await vault.getAddress(), mintAmount);

    return {
      vault, token, feeToken, deployer,
      signer1, signer2, signer3, backend, safeAddr, buyer, outsider,
      dailyCap, largeThreshold, minDailyCap, minLargeThreshold,
      maxDailyCap, maxLargeThreshold,
    };
  }

  async function depositFrom(vault, token, signer, amount) {
    return vault.connect(signer).deposit(await token.getAddress(), amount);
  }

  // Helper to get proposal ID from tx receipt
  async function getProposalId(vault, tx) {
    const receipt = await tx.wait();
    const log = receipt.logs.find(
      (l) => vault.interface.parseLog({ topics: l.topics, data: l.data })?.name === "ProposalCreated"
    );
    return vault.interface.parseLog({ topics: log.topics, data: log.data }).args[0];
  }

  // ===============================================================
  //                 TOKEN ALLOWLIST TESTS
  // ===============================================================

  describe("Token Allowlist", function () {
    it("should reject deposit of non-allowlisted token", async function () {
      const { vault, signer1 } = await loadFixture(deployVaultFixture);
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const randomToken = await MockERC20.deploy("Random", "RND", 18);
      await randomToken.mint(signer1.address, ethers.parseEther("1000"));
      await randomToken.connect(signer1).approve(await vault.getAddress(), ethers.parseEther("1000"));
      await expect(vault.connect(signer1).deposit(await randomToken.getAddress(), ethers.parseEther("100")))
        .to.be.revertedWith("Vault: token not on allowlist");
    });

    it("should allow deposit after token is allowlisted", async function () {
      const { vault, signer1 } = await loadFixture(deployVaultFixture);
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20.deploy("New Token", "NEW", 18);
      await newToken.mint(signer1.address, ethers.parseEther("1000"));
      await newToken.connect(signer1).approve(await vault.getAddress(), ethers.parseEther("1000"));
      await vault.connect(signer1).allowToken(await newToken.getAddress());
      await expect(vault.connect(signer1).deposit(await newToken.getAddress(), ethers.parseEther("100")))
        .to.emit(vault, "Deposited");
    });

    it("should reject allowToken from non-signer", async function () {
      const { vault, outsider, token } = await loadFixture(deployVaultFixture);
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const rnd = await MockERC20.deploy("Rnd", "RND", 18);
      await expect(vault.connect(outsider).allowToken(await rnd.getAddress()))
        .to.be.revertedWith("Vault: caller is not a signer");
    });

    it("should disallow token and block future deposits", async function () {
      const { vault, signer1, token } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).disallowToken(await token.getAddress());
      await expect(vault.connect(signer1).deposit(await token.getAddress(), ethers.parseEther("100")))
        .to.be.revertedWith("Vault: token not on allowlist");
    });
  });

  // ===============================================================
  //                   DEPOSIT TESTS
  // ===============================================================

  describe("Deposit", function () {
    it("should deposit standard tokens successfully", async function () {
      const { vault, token, signer1 } = await loadFixture(deployVaultFixture);
      const amount = ethers.parseEther("1000");

      await expect(depositFrom(vault, token, signer1, amount))
        .to.emit(vault, "Deposited")
        .withArgs(signer1.address, await token.getAddress(), amount, amount);

      expect(await vault.totalDepositedByUser(signer1.address, await token.getAddress())).to.equal(amount);
      expect(await vault.tokenBalance(await token.getAddress())).to.equal(amount);
    });

    it("should correctly account for fee-on-transfer tokens", async function () {
      const { vault, feeToken, signer1 } = await loadFixture(deployVaultFixture);
      const amount = ethers.parseEther("1000");
      const expectedReceived = ethers.parseEther("980"); // 2% fee

      await expect(depositFrom(vault, feeToken, signer1, amount))
        .to.emit(vault, "Deposited")
        .withArgs(signer1.address, await feeToken.getAddress(), amount, expectedReceived);

      // Vault records the REAL received amount, not the requested amount
      expect(await vault.totalDepositedByUser(signer1.address, await feeToken.getAddress()))
        .to.equal(expectedReceived);
      expect(await vault.tokenBalance(await feeToken.getAddress()))
        .to.equal(expectedReceived);
    });

    it("should revert on zero amount deposit", async function () {
      const { vault, token, signer1 } = await loadFixture(deployVaultFixture);
      await expect(depositFrom(vault, token, signer1, 0n))
        .to.be.revertedWith("Vault: zero amount");
    });

    it("should revert on zero token address", async function () {
      const { vault, signer1 } = await loadFixture(deployVaultFixture);
      await expect(
        vault.connect(signer1).deposit(ethers.ZeroAddress, ethers.parseEther("100"))
      ).to.be.revertedWith("Vault: zero token address");
    });

    it("should track cumulative deposits correctly", async function () {
      const { vault, token, signer1 } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("500"));
      await depositFrom(vault, token, signer1, ethers.parseEther("300"));
      expect(await vault.totalDepositedByUser(signer1.address, await token.getAddress()))
        .to.equal(ethers.parseEther("800"));
    });
  });

  // ===============================================================
  //                   RELEASE TESTS
  // ===============================================================

  describe("Release", function () {
    it("should release tokens to buyer", async function () {
      const { vault, token, signer1, backend, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("1000"));
      await expect(
        vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("200"))
      ).to.emit(vault, "Released")
        .withArgs(await token.getAddress(), buyer.address, ethers.parseEther("200"));
      expect(await token.balanceOf(buyer.address)).to.equal(ethers.parseEther("200"));
    });

    it("should revert release from non-backend", async function () {
      const { vault, token, signer1, outsider, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("1000"));
      await expect(
        vault.connect(outsider).release(await token.getAddress(), buyer.address, ethers.parseEther("100"))
      ).to.be.revertedWith("Vault: caller is not backend");
    });

    it("should revert release with zero amount", async function () {
      const { vault, token, signer1, backend, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("1000"));
      await expect(
        vault.connect(backend).release(await token.getAddress(), buyer.address, 0n)
      ).to.be.revertedWith("Vault: zero amount");
    });

    it("should revert release to zero address", async function () {
      const { vault, token, signer1, backend } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("1000"));
      await expect(
        vault.connect(backend).release(await token.getAddress(), ethers.ZeroAddress, ethers.parseEther("100"))
      ).to.be.revertedWith("Vault: zero recipient");
    });

    it("should revert when releasing exactly at daily cap + 1", async function () {
      const { vault, token, signer1, backend, buyer, dailyCap } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("200000"));
      // Release exactly at cap should succeed
      await vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("49000"));
      await vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("49000"));
      // 98000 used. Release 2000 more = 100000 exactly at cap should pass
      await vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("2000"));
      // Now at cap. 1 more should fail
      await expect(
        vault.connect(backend).release(await token.getAddress(), buyer.address, 1n)
      ).to.be.revertedWith("Vault: daily cap exceeded");
    });
  });

  // ===============================================================
  //                   BATCH RELEASE TESTS
  // ===============================================================

  describe("Batch Release", function () {
    it("should batch release and emit per-item Released events", async function () {
      const { vault, token, signer1, backend, buyer, outsider } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("10000"));
      const tokenAddr = await token.getAddress();
      const tx = await vault.connect(backend).batchRelease(
        [tokenAddr, tokenAddr],
        [buyer.address, outsider.address],
        [ethers.parseEther("100"), ethers.parseEther("200")]
      );
      await expect(tx).to.emit(vault, "Released").withArgs(tokenAddr, buyer.address, ethers.parseEther("100"));
      await expect(tx).to.emit(vault, "Released").withArgs(tokenAddr, outsider.address, ethers.parseEther("200"));
      await expect(tx).to.emit(vault, "BatchReleased").withArgs(2n, 0n);
    });

    it("should handle individual failures without blocking others", async function () {
      const { vault, token, signer1, backend, buyer, outsider } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("10000"));
      const tokenAddr = await token.getAddress();
      // Second item sends to zero address — will fail. Others should succeed.
      const tx = await vault.connect(backend).batchRelease(
        [tokenAddr, tokenAddr, tokenAddr],
        [buyer.address, ethers.ZeroAddress, outsider.address],
        [ethers.parseEther("100"), ethers.parseEther("200"), ethers.parseEther("300")]
      );
      await expect(tx).to.emit(vault, "ReleaseFailed");
      await expect(tx).to.emit(vault, "BatchReleased").withArgs(2n, 1n);
      expect(await token.balanceOf(buyer.address)).to.equal(ethers.parseEther("100"));
      expect(await token.balanceOf(outsider.address)).to.equal(ethers.parseEther("300"));
    });

    it("should revert batch from non-backend", async function () {
      const { vault, token, signer1, outsider, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("10000"));
      await expect(
        vault.connect(outsider).batchRelease([await token.getAddress()], [buyer.address], [ethers.parseEther("100")])
      ).to.be.revertedWith("Vault: caller is not backend");
    });

    it("should reject batch exceeding 50 items", async function () {
      const { vault, token, signer1, backend, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("500000"));
      const tokenAddr = await token.getAddress();
      const count = 51;
      await expect(
        vault.connect(backend).batchRelease(
          Array(count).fill(tokenAddr), Array(count).fill(buyer.address), Array(count).fill(ethers.parseEther("100"))
        )
      ).to.be.revertedWith("Vault: batch too large");
    });
  });

  // ===============================================================
  //                   DAILY CAP TESTS
  // ===============================================================

  describe("Daily Withdrawal Cap", function () {
    it("should revert when daily cap exceeded", async function () {
      const { vault, token, signer1, backend, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("200000"));
      await vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("49000"));
      await vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("49000"));
      await expect(
        vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("3000"))
      ).to.be.revertedWith("Vault: daily cap exceeded");
    });

    it("should reset daily cap the next day", async function () {
      const { vault, token, signer1, backend, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("200000"));
      await vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("49000"));
      await vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("49000"));
      await time.increase(86400);
      await expect(
        vault.connect(backend).release(await token.getAddress(), buyer.address, ethers.parseEther("1000"))
      ).to.not.be.reverted;
    });

    it("should enforce minimum floor on daily cap", async function () {
      const { vault, signer1, minDailyCap } = await loadFixture(deployVaultFixture);
      await expect(
        vault.connect(signer1).setDailyCap(ethers.ZeroAddress, minDailyCap - 1n)
      ).to.be.revertedWith("Vault: below minimum cap");
    });

    it("should enforce minimum floor on large threshold", async function () {
      const { vault, signer1, minLargeThreshold } = await loadFixture(deployVaultFixture);
      await expect(
        vault.connect(signer1).setLargeThreshold(ethers.ZeroAddress, minLargeThreshold - 1n)
      ).to.be.revertedWith("Vault: below minimum threshold");
    });

    it("should report remaining daily capacity correctly", async function () {
      const { vault, token, signer1, backend, buyer, dailyCap } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("200000"));
      const used = ethers.parseEther("30000");
      await vault.connect(backend).release(await token.getAddress(), buyer.address, used);
      expect(await vault.remainingDailyCapacity(await token.getAddress())).to.equal(dailyCap - used);
    });
  });

  // ===============================================================
  //                   LARGE WITHDRAWAL TESTS
  // ===============================================================

  describe("Large Withdrawal Timelock", function () {
    it("should require timelock for amounts above threshold", async function () {
      const { vault, token, signer1, backend, buyer, largeThreshold } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("200000"));
      await expect(
        vault.connect(backend).release(await token.getAddress(), buyer.address, largeThreshold + 1n)
      ).to.be.revertedWith("Vault: exceeds threshold, use queueLargeRelease()");
    });

    it("should queue and execute large release after timelock", async function () {
      const { vault, token, signer1, backend, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("200000"));
      const amount = ethers.parseEther("60000");
      const tokenAddr = await token.getAddress();

      await vault.connect(backend).queueLargeRelease(tokenAddr, buyer.address, amount);
      const timelockId = 0;

      await expect(vault.connect(backend).executeLargeRelease(timelockId))
        .to.be.revertedWith("Vault: timelock not expired");

      await time.increase(24 * 60 * 60);

      await expect(vault.connect(backend).executeLargeRelease(timelockId))
        .to.emit(vault, "LargeWithdrawalExecuted");
      expect(await token.balanceOf(buyer.address)).to.equal(amount);
    });

    it("should prevent double execution of large release", async function () {
      const { vault, token, signer1, backend, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("200000"));
      await vault.connect(backend).queueLargeRelease(await token.getAddress(), buyer.address, ethers.parseEther("60000"));
      await time.increase(24 * 60 * 60);
      await vault.connect(backend).executeLargeRelease(0);
      await expect(vault.connect(backend).executeLargeRelease(0))
        .to.be.revertedWith("Vault: already executed");
    });

    it("should allow single signer to cancel non-emergency timelock", async function () {
      const { vault, token, signer1, backend, buyer } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("200000"));
      await vault.connect(backend).queueLargeRelease(await token.getAddress(), buyer.address, ethers.parseEther("60000"));
      await vault.connect(signer1).cancelTimelock(0);
      await time.increase(24 * 60 * 60);
      await expect(vault.connect(backend).executeLargeRelease(0))
        .to.be.revertedWith("Vault: cancelled");
    });
  });

  // ===============================================================
  //                   PAUSE / UNPAUSE TESTS
  // ===============================================================

  describe("Pause / Unpause", function () {
    it("should revert deposit when paused", async function () {
      const { vault, token, signer1 } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).pause();
      await expect(depositFrom(vault, token, signer1, ethers.parseEther("100")))
        .to.be.revertedWithCustomError(vault, "EnforcedPause");
    });

    it("should require 2-of-3 to unpause", async function () {
      const { vault, signer1, signer2 } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).pause();
      const tx = await vault.connect(signer1).proposeUnpause();
      const proposalId = await getProposalId(vault, tx);
      expect(await vault.paused()).to.be.true;
      await vault.connect(signer2).approveUnpause(proposalId);
      expect(await vault.paused()).to.be.false;
    });

    it("should enforce 4-hour cooldown after unpause", async function () {
      const { vault, signer1, signer2, signer3 } = await loadFixture(deployVaultFixture);
      await vault.connect(signer1).pause();
      const tx = await vault.connect(signer1).proposeUnpause();
      const pid = await getProposalId(vault, tx);
      await vault.connect(signer2).approveUnpause(pid);
      // Try to pause again immediately — should fail
      await expect(vault.connect(signer3).pause())
        .to.be.revertedWith("Vault: pause cooldown active");
      // Advance past cooldown
      await time.increase(4 * 60 * 60 + 1);
      await expect(vault.connect(signer3).pause()).to.not.be.reverted;
    });

    it("should revert pause from non-signer", async function () {
      const { vault, outsider } = await loadFixture(deployVaultFixture);
      await expect(vault.connect(outsider).pause())
        .to.be.revertedWith("Vault: caller is not a signer");
    });
  });

  // ===============================================================
  //                   EMERGENCY WITHDRAWAL TESTS
  // ===============================================================

  describe("Emergency Withdrawal", function () {
    it("should require 2-of-3 multisig and 72-hour timelock", async function () {
      const { vault, token, signer1, signer2, safeAddr } = await loadFixture(deployVaultFixture);
      const depositAmt = ethers.parseEther("5000");
      await depositFrom(vault, token, signer1, depositAmt);

      const tx = await vault.connect(signer1).proposeEmergencyWithdraw(await token.getAddress());
      const proposalId = await getProposalId(vault, tx);
      await vault.connect(signer2).approveEmergencyWithdraw(proposalId);

      // Revert before 72h
      await expect(vault.connect(signer1).executeEmergencyWithdraw(0))
        .to.be.revertedWith("Vault: timelock not expired");

      await time.increase(72 * 60 * 60);
      await vault.connect(signer1).executeEmergencyWithdraw(0);
      expect(await token.balanceOf(safeAddr.address)).to.equal(depositAmt);
    });

    it("should require 2-of-3 to cancel emergency timelock", async function () {
      const { vault, token, signer1, signer2, signer3 } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("5000"));

      const tx = await vault.connect(signer1).proposeEmergencyWithdraw(await token.getAddress());
      const proposalId = await getProposalId(vault, tx);
      await vault.connect(signer2).approveEmergencyWithdraw(proposalId);

      // Single signer cancel attempt — should NOT cancel (needs 2)
      await vault.connect(signer3).cancelTimelock(0);
      const op = await vault.timelocks(0);
      expect(op.cancelled).to.be.false; // Still not cancelled

      // Second cancel vote — should cancel
      await vault.connect(signer1).cancelTimelock(0);
      const op2 = await vault.timelocks(0);
      expect(op2.cancelled).to.be.true;
    });

    it("should prevent double execution of emergency withdraw", async function () {
      const { vault, token, signer1, signer2 } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("5000"));
      const tx = await vault.connect(signer1).proposeEmergencyWithdraw(await token.getAddress());
      const pid = await getProposalId(vault, tx);
      await vault.connect(signer2).approveEmergencyWithdraw(pid);
      await time.increase(72 * 60 * 60);
      await vault.connect(signer1).executeEmergencyWithdraw(0);
      await expect(vault.connect(signer1).executeEmergencyWithdraw(0))
        .to.be.revertedWith("Vault: already executed");
    });

    it("should revert emergency withdrawal from non-signer", async function () {
      const { vault, token, signer1, signer2, outsider } = await loadFixture(deployVaultFixture);
      await depositFrom(vault, token, signer1, ethers.parseEther("5000"));
      const tx = await vault.connect(signer1).proposeEmergencyWithdraw(await token.getAddress());
      const pid = await getProposalId(vault, tx);
      await vault.connect(signer2).approveEmergencyWithdraw(pid);
      await time.increase(72 * 60 * 60);
      await expect(vault.connect(outsider).executeEmergencyWithdraw(0))
        .to.be.revertedWith("Vault: caller is not a signer");
    });
  });

  // ===============================================================
  //                   CONSTRUCTOR VALIDATION
  // ===============================================================

  describe("Constructor", function () {
    it("should reject duplicate signers", async function () {
      const { signer1, signer2, backend, safeAddr } = await loadFixture(deployVaultFixture);
      const Vault = await ethers.getContractFactory("PreselloVault");
      await expect(Vault.deploy(
        [signer1.address, signer1.address, signer2.address],
        backend.address, safeAddr.address,
        ethers.parseEther("100000"), ethers.parseEther("50000"),
        ethers.parseEther("1000"), ethers.parseEther("500"),
        ethers.parseEther("10000000"), ethers.parseEther("5000000")
      )).to.be.revertedWith("Vault: duplicate signer");
    });

    it("should reject zero backend address", async function () {
      const { signer1, signer2, signer3, safeAddr } = await loadFixture(deployVaultFixture);
      const Vault = await ethers.getContractFactory("PreselloVault");
      await expect(Vault.deploy(
        [signer1.address, signer2.address, signer3.address],
        ethers.ZeroAddress, safeAddr.address,
        ethers.parseEther("100000"), ethers.parseEther("50000"),
        ethers.parseEther("1000"), ethers.parseEther("500"),
        ethers.parseEther("10000000"), ethers.parseEther("5000000")
      )).to.be.revertedWith("Vault: zero backend address");
    });

    it("should reject daily cap < large threshold", async function () {
      const { signer1, signer2, signer3, backend, safeAddr } = await loadFixture(deployVaultFixture);
      const Vault = await ethers.getContractFactory("PreselloVault");
      await expect(Vault.deploy(
        [signer1.address, signer2.address, signer3.address],
        backend.address, safeAddr.address,
        ethers.parseEther("10000"), ethers.parseEther("50000"), // cap < threshold
        ethers.parseEther("1000"), ethers.parseEther("500"),
        ethers.parseEther("10000000"), ethers.parseEther("5000000")
      )).to.be.revertedWith("Vault: daily cap must be >= threshold");
    });

    it("should reject signer == backend", async function () {
      const { signer1, signer2, signer3, safeAddr } = await loadFixture(deployVaultFixture);
      const Vault = await ethers.getContractFactory("PreselloVault");
      await expect(Vault.deploy(
        [signer1.address, signer2.address, signer3.address],
        signer1.address, safeAddr.address, // signer1 == backend
        ethers.parseEther("100000"), ethers.parseEther("50000"),
        ethers.parseEther("1000"), ethers.parseEther("500"),
        ethers.parseEther("10000000"), ethers.parseEther("5000000")
      )).to.be.revertedWith("Vault: signer == backend");
    });

    it("should reject signer == safe", async function () {
      const { signer1, signer2, signer3, backend } = await loadFixture(deployVaultFixture);
      const Vault = await ethers.getContractFactory("PreselloVault");
      await expect(Vault.deploy(
        [signer1.address, signer2.address, signer3.address],
        backend.address, signer1.address, // signer1 == safe
        ethers.parseEther("100000"), ethers.parseEther("50000"),
        ethers.parseEther("1000"), ethers.parseEther("500"),
        ethers.parseEther("10000000"), ethers.parseEther("5000000")
      )).to.be.revertedWith("Vault: signer == safe");
    });
  });
});
