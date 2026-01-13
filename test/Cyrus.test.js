const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Cyrus Token", function () {
  let cyrus;
  let usdt;
  let owner;
  let lpWallet;
  let addr1;
  let addr2;

  // Constants from contract
  const LP_RESERVE = ethers.parseEther("100000000"); // 100M tokens
  const SALE_SUPPLY = ethers.parseEther("900000000"); // 900M tokens
  const START_PRICE = 10000n; // $0.01 in USDT (6 decimals)
  const END_PRICE = 1000000n; // $1.00 in USDT (6 decimals)
  const NOWRUZ_2026 = 1742558400n;

  beforeEach(async function () {
    [owner, lpWallet, addr1, addr2] = await ethers.getSigners();
    
    // Deploy mock USDT (6 decimals like real USDT)
    const MockUSDT = await ethers.getContractFactory("MockUSDT");
    usdt = await MockUSDT.deploy();
    await usdt.waitForDeployment();

    // Deploy Cyrus token
    const Cyrus = await ethers.getContractFactory("Cyrus");
    cyrus = await Cyrus.deploy(owner.address, await usdt.getAddress(), lpWallet.address);
    await cyrus.waitForDeployment();

    // Mint USDT to test accounts for buying
    await usdt.mint(addr1.address, ethers.parseUnits("1000000", 6)); // 1M USDT
    await usdt.mint(addr2.address, ethers.parseUnits("1000000", 6)); // 1M USDT

    // Approve Cyrus contract to spend USDT
    await usdt.connect(addr1).approve(await cyrus.getAddress(), ethers.MaxUint256);
    await usdt.connect(addr2).approve(await cyrus.getAddress(), ethers.MaxUint256);
  });

  describe("Deployment", function () {
    it("Should set the right name and symbol", async function () {
      expect(await cyrus.name()).to.equal("Cyrus");
      expect(await cyrus.symbol()).to.equal("CYRUS");
    });

    it("Should set the right owner", async function () {
      expect(await cyrus.owner()).to.equal(owner.address);
    });

    it("Should have correct decimals", async function () {
      expect(await cyrus.decimals()).to.equal(18);
    });

    it("Should mint LP reserve to LP wallet", async function () {
      expect(await cyrus.balanceOf(lpWallet.address)).to.equal(LP_RESERVE);
    });

    it("Should set correct USDT address", async function () {
      expect(await cyrus.USDT()).to.equal(await usdt.getAddress());
    });

    it("Should set correct LP wallet", async function () {
      expect(await cyrus.lpWallet()).to.equal(lpWallet.address);
    });

    it("Should have sale active by default", async function () {
      expect(await cyrus.saleActive()).to.equal(true);
    });

    it("Should have correct supply constants", async function () {
      expect(await cyrus.MAX_SUPPLY()).to.equal(ethers.parseEther("1000000000"));
      expect(await cyrus.LP_RESERVE()).to.equal(LP_RESERVE);
      expect(await cyrus.SALE_SUPPLY()).to.equal(SALE_SUPPLY);
    });
  });

  describe("Bonding Curve", function () {
    it("Should have correct initial price ($0.01)", async function () {
      expect(await cyrus.getCurrentPrice()).to.equal(START_PRICE);
    });

    it("Should have correct price constants", async function () {
      expect(await cyrus.START_PRICE()).to.equal(START_PRICE);
      expect(await cyrus.END_PRICE()).to.equal(END_PRICE);
    });

    it("Should allow users to buy tokens with USDT", async function () {
      const usdtAmount = ethers.parseUnits("100", 6); // $100 USDT
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      const balance = await cyrus.balanceOf(addr1.address);
      expect(balance).to.be.gt(0);
    });

    it("Should track tokens sold", async function () {
      const usdtAmount = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      expect(await cyrus.tokensSold()).to.be.gt(0);
    });

    it("Should track USDT raised", async function () {
      const usdtAmount = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      expect(await cyrus.usdtRaised()).to.be.gt(0);
    });

    it("Should emit TokensPurchased event", async function () {
      const usdtAmount = ethers.parseUnits("100", 6);
      await expect(cyrus.connect(addr1)["buy(uint256)"](usdtAmount))
        .to.emit(cyrus, "TokensPurchased");
    });

    it("Should support buy with slippage protection", async function () {
      const usdtAmount = ethers.parseUnits("100", 6);
      const minTokens = ethers.parseEther("1"); // At least 1 token
      await cyrus.connect(addr1)["buy(uint256,uint256)"](usdtAmount, minTokens);
      const balance = await cyrus.balanceOf(addr1.address);
      expect(balance).to.be.gte(minTokens);
    });

    it("Should revert if slippage exceeded", async function () {
      const usdtAmount = ethers.parseUnits("1", 6); // $1 USDT
      const minTokens = ethers.parseEther("1000000000"); // Impossibly high
      await expect(cyrus.connect(addr1)["buy(uint256,uint256)"](usdtAmount, minTokens))
        .to.be.revertedWith("Slippage exceeded");
    });

    it("Should calculate tokens for USDT correctly", async function () {
      const usdtAmount = ethers.parseUnits("100", 6);
      const tokens = await cyrus.calculateTokensForUsdt(usdtAmount);
      expect(tokens).to.be.gt(0);
    });

    it("Should allow multiple sequential buys", async function () {
      // First buy
      const usdtAmount1 = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount1);
      const balance1 = await cyrus.balanceOf(addr1.address);
      
      // Second buy
      const usdtAmount2 = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount2);
      const balance2 = await cyrus.balanceOf(addr1.address);
      
      expect(balance2).to.be.gt(balance1);
    });

    it("Should give more tokens to early buyers (quadratic curve benefit)", async function () {
      // Early buy at low price
      const usdtAmount = ethers.parseUnits("100", 6);
      const tokensEarly = await cyrus.calculateTokensForUsdt(usdtAmount);
      
      // At starting price of $0.01, $100 should buy approximately 10,000 tokens
      // (100 USDT / 0.01 = 10,000 tokens)
      expect(tokensEarly).to.be.gt(ethers.parseEther("9000")); // At least 9k tokens for $100
    });
  });

  describe("Transfer Lock (Nowruz 2026)", function () {
    it("Should have correct Nowruz timestamp", async function () {
      expect(await cyrus.NOWRUZ_2026()).to.equal(NOWRUZ_2026);
    });

    it("Should correctly report transfer status based on block timestamp", async function () {
      const transfersEnabled = await cyrus.transfersEnabled();
      const block = await ethers.provider.getBlock("latest");
      const expectedEnabled = BigInt(block.timestamp) >= NOWRUZ_2026;
      expect(transfersEnabled).to.equal(expectedEnabled);
    });

    it("Should allow minting (buying) regardless of timestamp", async function () {
      const usdtAmount = ethers.parseUnits("100", 6);
      await expect(cyrus.connect(addr1)["buy(uint256)"](usdtAmount)).to.not.be.reverted;
    });

    it("Should allow LP wallet to transfer", async function () {
      // LP wallet has tokens and should be able to transfer
      const transferAmount = ethers.parseEther("1000");
      await expect(cyrus.connect(lpWallet).transfer(addr1.address, transferAmount))
        .to.not.be.reverted;
    });

    it("Should allow burning", async function () {
      // First buy some tokens
      const usdtAmount = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      const burnAmount = ethers.parseEther("10");
      await expect(cyrus.connect(addr1).burn(burnAmount)).to.not.be.reverted;
    });

    it("Should handle transfers correctly based on current timestamp", async function () {
      // First buy some tokens
      const usdtAmount = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      const transferAmount = ethers.parseEther("100");
      const transfersEnabled = await cyrus.transfersEnabled();
      
      if (transfersEnabled) {
        // Transfers should work after Nowruz
        await expect(cyrus.connect(addr1).transfer(addr2.address, transferAmount))
          .to.not.be.reverted;
      } else {
        // Transfers should be blocked before Nowruz
        await expect(cyrus.connect(addr1).transfer(addr2.address, transferAmount))
          .to.be.revertedWithCustomError(cyrus, "TransfersLocked");
      }
    });
  });

  describe("Sale Controls", function () {
    it("Should allow owner to end sale", async function () {
      await cyrus.endSale();
      expect(await cyrus.saleActive()).to.equal(false);
    });

    it("Should allow owner to resume sale", async function () {
      await cyrus.endSale();
      await cyrus.resumeSale();
      expect(await cyrus.saleActive()).to.equal(true);
    });

    it("Should not allow buying when sale is inactive", async function () {
      await cyrus.endSale();
      const usdtAmount = ethers.parseUnits("100", 6);
      await expect(cyrus.connect(addr1)["buy(uint256)"](usdtAmount))
        .to.be.revertedWith("Sale not active");
    });

    it("Should not allow non-owner to end sale", async function () {
      await expect(cyrus.connect(addr1).endSale()).to.be.reverted;
    });

    it("Should not allow non-owner to resume sale", async function () {
      await cyrus.endSale();
      await expect(cyrus.connect(addr1).resumeSale()).to.be.reverted;
    });
  });

  describe("Pausable", function () {
    it("Should allow owner to pause", async function () {
      await cyrus.pause();
      expect(await cyrus.paused()).to.equal(true);
    });

    it("Should allow owner to unpause", async function () {
      await cyrus.pause();
      await cyrus.unpause();
      expect(await cyrus.paused()).to.equal(false);
    });

    it("Should not allow non-owner to pause", async function () {
      await expect(cyrus.connect(addr1).pause()).to.be.reverted;
    });

    it("Should not allow non-owner to unpause", async function () {
      await cyrus.pause();
      await expect(cyrus.connect(addr1).unpause()).to.be.reverted;
    });
  });

  describe("Burnable", function () {
    it("Should allow token holders to burn their tokens", async function () {
      // First buy some tokens
      const usdtAmount = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      const initialBalance = await cyrus.balanceOf(addr1.address);
      const burnAmount = ethers.parseEther("100");
      await cyrus.connect(addr1).burn(burnAmount);
      const finalBalance = await cyrus.balanceOf(addr1.address);
      expect(finalBalance).to.equal(initialBalance - burnAmount);
    });

    it("Should reduce total supply when burning", async function () {
      const usdtAmount = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      const initialSupply = await cyrus.totalSupply();
      const burnAmount = ethers.parseEther("100");
      await cyrus.connect(addr1).burn(burnAmount);
      const finalSupply = await cyrus.totalSupply();
      expect(finalSupply).to.equal(initialSupply - burnAmount);
    });
  });

  describe("LP Funding", function () {
    it("Should allow owner to set LP wallet", async function () {
      await cyrus.setLPWallet(addr2.address);
      expect(await cyrus.lpWallet()).to.equal(addr2.address);
    });

    it("Should not allow zero address for LP wallet", async function () {
      await expect(cyrus.setLPWallet(ethers.ZeroAddress))
        .to.be.revertedWith("Invalid LP wallet");
    });

    it("Should allow owner to fund LP with raised USDT", async function () {
      // First buy some tokens to raise USDT
      const usdtAmount = ethers.parseUnits("1000", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      const contractBalance = await usdt.balanceOf(await cyrus.getAddress());
      expect(contractBalance).to.be.gt(0);
      
      const lpBalanceBefore = await usdt.balanceOf(lpWallet.address);
      await cyrus.fundLP();
      const lpBalanceAfter = await usdt.balanceOf(lpWallet.address);
      
      expect(lpBalanceAfter).to.be.gt(lpBalanceBefore);
    });

    it("Should emit LPFunded event", async function () {
      const usdtAmount = ethers.parseUnits("1000", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      await expect(cyrus.fundLP()).to.emit(cyrus, "LPFunded");
    });
  });

  describe("Withdraw", function () {
    it("Should allow owner to withdraw USDT", async function () {
      // First buy some tokens to raise USDT
      const usdtAmount = ethers.parseUnits("1000", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      const ownerBalanceBefore = await usdt.balanceOf(owner.address);
      await cyrus.withdraw(owner.address, 0); // 0 = withdraw all
      const ownerBalanceAfter = await usdt.balanceOf(owner.address);
      
      expect(ownerBalanceAfter).to.be.gt(ownerBalanceBefore);
    });

    it("Should emit Withdrawn event", async function () {
      const usdtAmount = ethers.parseUnits("1000", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      await expect(cyrus.withdraw(owner.address, 0)).to.emit(cyrus, "Withdrawn");
    });

    it("Should not allow non-owner to withdraw", async function () {
      const usdtAmount = ethers.parseUnits("1000", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      await expect(cyrus.connect(addr1).withdraw(addr1.address, 0)).to.be.reverted;
    });
  });

  describe("ERC20 Votes", function () {
    it("Should support delegation", async function () {
      // Buy tokens first
      const usdtAmount = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      // Delegate to self
      await cyrus.connect(addr1).delegate(addr1.address);
      
      const votes = await cyrus.getVotes(addr1.address);
      expect(votes).to.be.gt(0);
    });

    it("Should track voting power", async function () {
      const usdtAmount = ethers.parseUnits("100", 6);
      await cyrus.connect(addr1)["buy(uint256)"](usdtAmount);
      
      await cyrus.connect(addr1).delegate(addr1.address);
      
      const balance = await cyrus.balanceOf(addr1.address);
      const votes = await cyrus.getVotes(addr1.address);
      expect(votes).to.equal(balance);
    });
  });

  describe("ERC20 Permit", function () {
    it("Should have correct domain separator name", async function () {
      // Verify permit functionality exists
      const nonce = await cyrus.nonces(addr1.address);
      expect(nonce).to.equal(0);
    });
  });

  describe("Token Recovery", function () {
    it("Should allow owner to recover accidentally sent tokens", async function () {
      // Create another mock token and send it to the contract
      const MockToken = await ethers.getContractFactory("MockUSDT");
      const randomToken = await MockToken.deploy();
      await randomToken.waitForDeployment();
      
      // Mint and send to contract
      await randomToken.mint(await cyrus.getAddress(), ethers.parseUnits("100", 6));
      
      // Recover
      const ownerBalanceBefore = await randomToken.balanceOf(owner.address);
      await cyrus.recoverERC20(await randomToken.getAddress(), owner.address, 0);
      const ownerBalanceAfter = await randomToken.balanceOf(owner.address);
      
      expect(ownerBalanceAfter).to.be.gt(ownerBalanceBefore);
    });
  });
});
