import { expect } from "chai";

import { MiniMeToken } from "typechain-types";

import { loadContract } from "lib";

describe("Fast tests for testing CI integration", () => {
  it("Check LDO amount at address 3", async () => {
    const ldo = await loadContract<MiniMeToken>("MiniMeToken", "0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32");

    const balance = await ldo?.balanceOf("0x0000000000000000000000000000000000000777");

    expect(balance).to.be.equal(10000000000000000000000n);
  });
});
