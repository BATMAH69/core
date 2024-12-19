import { expect } from "chai";

import { discover } from "../../lib/protocol/discover";

describe("Fast tests for testing CI integration", () => {
  it("Check LDO amount at address 3", async () => {
    const { contracts } = await discover();

    const { lido } = contracts;

    const balance3 = await lido.balanceOf("0x0000000000000000000000000000000000000777");
    const balance1 = await lido.balanceOf("0x0000000000000000000000000000000000000001");

    expect(balance3).to.be.equal(0);
    expect(balance1).to.be.equal(2433715748);
  });
});
