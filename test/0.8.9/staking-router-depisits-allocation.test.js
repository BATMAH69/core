const hre = require('hardhat')
const { assert } = require('chai')
const { assertBn } = require('@aragon/contract-helpers-test/src/asserts')
const StakingRouter = artifacts.require('StakingRouter')
const StakingModuleMock = artifacts.require('StakingModuleMock')
const DepositContractMock = artifacts.require('DepositContractMock.sol')

contract('StakingRouter', (accounts) => {
  let evmSnapshotId
  let depositContract, stakingRouter
  let curatedStakingModuleMock, soloStakingModuleMock, dvtStakingModuleMock
  const [deployer, lido, admin] = accounts

  before(async () => {
    depositContract = await DepositContractMock.new({ from: deployer })
    stakingRouter = await StakingRouter.new(depositContract.address, lido, { from: deployer })
    ;[curatedStakingModuleMock, soloStakingModuleMock, dvtStakingModuleMock] = await Promise.all([
      StakingModuleMock.new({ from: deployer }),
      StakingModuleMock.new({ from: deployer }),
      StakingModuleMock.new({ from: deployer })
    ])

    await stakingRouter.initialize(admin, { from: deployer })

    // Set up the staking router permissions.
    const [MANAGE_WITHDRAWAL_KEY_ROLE, MODULE_PAUSE_ROLE, MODULE_CONTROL_ROLE] = await Promise.all([
      stakingRouter.MANAGE_WITHDRAWAL_KEY_ROLE(),
      stakingRouter.MODULE_PAUSE_ROLE(),
      stakingRouter.MODULE_CONTROL_ROLE()
    ])

    await stakingRouter.grantRole(MANAGE_WITHDRAWAL_KEY_ROLE, admin, { from: admin })
    await stakingRouter.grantRole(MODULE_PAUSE_ROLE, admin, { from: admin })
    await stakingRouter.grantRole(MODULE_CONTROL_ROLE, admin, { from: admin })

    evmSnapshotId = await hre.ethers.provider.send('evm_snapshot', [])
  })

  afterEach(async () => {
    await hre.ethers.provider.send('evm_revert', [evmSnapshotId])
    evmSnapshotId = await hre.ethers.provider.send('evm_snapshot', [])
  })

  describe('One staking module', () => {
    beforeEach(async () => {
      await stakingRouter.addModule(
        'Curated',
        curatedStakingModuleMock.address,
        10_000, // 100 %
        1_000, // 10 %
        5_000, // 50 %
        { from: admin }
      )
    })

    it('getAllocatedDepositsDistribution :: empty staking module', async () => {
      const depositsDistribution = await stakingRouter.getAllocatedDepositsDistribution(0)
      assert.equal(depositsDistribution.length, 1)
      assertBn(depositsDistribution[0], 0)
    })

    it('getAllocatedDepositsDistribution :: staking module with zero used keys', async () => {
      await curatedStakingModuleMock.setTotalKeys(500)
      assertBn(await curatedStakingModuleMock.getTotalKeys(), 500)

      const depositsDistribution = await stakingRouter.getAllocatedDepositsDistribution(1000)
      assert.equal(depositsDistribution.length, 1)
      assertBn(depositsDistribution[0], 500)
    })

    it('getAllocatedDepositsDistribution :: staking module with non zero used keys', async () => {
      await curatedStakingModuleMock.setTotalKeys(500)
      assertBn(await curatedStakingModuleMock.getTotalKeys(), 500)

      await curatedStakingModuleMock.setTotalUsedKeys(250)
      assertBn(await curatedStakingModuleMock.getTotalUsedKeys(), 250)

      const depositsDistribution = await stakingRouter.getAllocatedDepositsDistribution(1000)
      assert.equal(depositsDistribution.length, 1)
      assertBn(depositsDistribution[0], 250)
    })
  })

  describe('Two staking modules', () => {
    beforeEach(async () => {
      await stakingRouter.addModule(
        'Curated',
        curatedStakingModuleMock.address,
        10_000, // 100 %
        1_000, // 10 %
        5_000, // 50 %
        { from: admin }
      )
      await stakingRouter.addModule(
        'Solo',
        soloStakingModuleMock.address,
        200, // 2 %
        5_000, // 50 %
        0, // 0 %
        { from: admin }
      )
    })

    it('getAllocatedDepositsDistribution :: equal available keys', async () => {
      await curatedStakingModuleMock.setTotalKeys(5000)
      assertBn(await curatedStakingModuleMock.getTotalKeys(), 5000)

      await curatedStakingModuleMock.setTotalUsedKeys(4500)
      assertBn(await curatedStakingModuleMock.getTotalUsedKeys(), 4500)

      await soloStakingModuleMock.setTotalKeys(300)
      assertBn(await soloStakingModuleMock.getTotalKeys(), 300)

      await soloStakingModuleMock.setTotalUsedKeys(50)
      assertBn(await soloStakingModuleMock.getTotalUsedKeys(), 50)

      const depositsDistribution = await stakingRouter.getAllocatedDepositsDistribution(5000)
      assert.equal(depositsDistribution.length, 2)
      assertBn(depositsDistribution[0], 500)
      assertBn(depositsDistribution[1], 50)
    })
  })
})
