import { expect } from "chai";

import { discover } from "../../lib/protocol/discover";

describe("Fast tests for testing CI integration", () => {
  it("Check LDO amount at address 3", async () => {
    const { contracts } = await discover();

    const { lido } = contracts;

    const balance3 = await lido.balanceOf("0x0000000000000000000000000000000000000003");

    expect(balance3).to.be.equal(0);
  });
});
