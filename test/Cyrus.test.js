const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Cyrus Token", function () {
  let cyrus;
  let owner;
  let addr1;
  let addr2;

  beforeEach(async function () {
    [owner, addr1, addr2] = await ethers.getSigners();
    const Cyrus = await ethers.getContractFactory("Cyrus");
    cyrus = await Cyrus.deploy(owner.address);
    await cyrus.waitForDeployment();
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

    it("Should mint LP reserve to owner", async function () {
      const lpReserve = ethers.parseEther("100000000"); // 100M
      expect(await cyrus.balanceOf(owner.address)).to.equal(lpReserve);
    });
  });

  describe("Bonding Curve", function () {
    it("Should have correct initial price", async function () {
      const startingPrice = ethers.parseEther("0.0000001");
      expect(await cyrus.getCurrentPrice()).to.equal(startingPrice);
    });

    it("Should allow users to buy tokens", async function () {
      const ethAmount = ethers.parseEther("0.01");
      await cyrus.connect(addr1).buy({ value: ethAmount });
      const balance = await cyrus.balanceOf(addr1.address);
      expect(balance).to.be.gt(0);
    });

    it("Should track tokens sold", async function () {
      const ethAmount = ethers.parseEther("0.01");
      await cyrus.connect(addr1).buy({ value: ethAmount });
      expect(await cyrus.tokensSold()).to.be.gt(0);
    });

    it("Should track ETH raised", async function () {
      const ethAmount = ethers.parseEther("0.01");
      await cyrus.connect(addr1).buy({ value: ethAmount });
      expect(await cyrus.ethRaised()).to.equal(ethAmount);
    });

    it("Should emit TokensPurchased event", async function () {
      const ethAmount = ethers.parseEther("0.01");
      await expect(cyrus.connect(addr1).buy({ value: ethAmount }))
        .to.emit(cyrus, "TokensPurchased");
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
      const ethAmount = ethers.parseEther("0.01");
      await expect(cyrus.connect(addr1).buy({ value: ethAmount }))
        .to.be.revertedWith("Sale not active");
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
  });

  describe("Burnable", function () {
    it("Should allow token holders to burn their tokens", async function () {
      // Owner has LP reserve tokens
      const burnAmount = ethers.parseEther("100");
      const initialBalance = await cyrus.balanceOf(owner.address);
      await cyrus.burn(burnAmount);
      const finalBalance = await cyrus.balanceOf(owner.address);
      expect(finalBalance).to.equal(initialBalance - burnAmount);
    });
  });

  describe("LP Funding", function () {
    it("Should allow owner to set LP address", async function () {
      await cyrus.setLPAddress(addr2.address);
      expect(await cyrus.lpAddress()).to.equal(addr2.address);
    });

    it("Should not allow zero address for LP", async function () {
      await expect(cyrus.setLPAddress(ethers.ZeroAddress))
        .to.be.revertedWith("Invalid LP address");
    });
  });
});
