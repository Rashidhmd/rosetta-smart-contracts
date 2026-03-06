use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
    start_cheat_block_number_global, stop_cheat_block_number_global,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use vesting::vesting::{IVestingDispatcher, IVestingDispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn deployer() -> ContractAddress    { 'deployer'.try_into().unwrap() }
fn beneficiary() -> ContractAddress { 'beneficiary'.try_into().unwrap() }
fn stranger() -> ContractAddress    { 'stranger'.try_into().unwrap() }

const INITIAL: u256  = 1000_u256;
const START: u64     = 100_u64;
const DURATION: u64  = 100_u64;   // vesting: block 100 → block 200
const END: u64       = START + DURATION;

fn deploy_token() -> ContractAddress {
    let class = declare("ERC20Mock").unwrap().contract_class();
    let name: ByteArray   = "TestToken";
    let symbol: ByteArray = "TTK";
    let supply: u256      = 100_000_u256;

    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    supply.serialize(ref calldata);
    calldata.append(deployer().into());

    let (token_addr, _) = class.deploy(@calldata).unwrap();
    token_addr
}

fn deploy_vesting(token_addr: ContractAddress) -> ContractAddress {
    let class = declare("Vesting").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(beneficiary().into());
    calldata.append(START.into());
    calldata.append(DURATION.into());
    INITIAL.serialize(ref calldata);
    calldata.append(token_addr.into());

    // ✅ activate cheat FIRST so precalculate uses the same deployer as deploy()
    start_cheat_caller_address_global(deployer());

    // ✅ now precalculate — address is deterministic based on deployer() 
    let vesting_addr = class.precalculate_address(@calldata);

    // ✅ approve the correctly calculated address
    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, deployer());
    token.approve(vesting_addr, INITIAL);
    stop_cheat_caller_address(token_addr);

    // ✅ deploy — constructor finds the approval and transfer_from succeeds
    let (deployed_addr, _) = class.deploy(@calldata).unwrap();
    stop_cheat_caller_address_global();

    deployed_addr
}

fn setup() -> (ContractAddress, ContractAddress) {
    let token_addr   = deploy_token();
    let vesting_addr = deploy_vesting(token_addr);
    (token_addr, vesting_addr)
}

// helper: beneficiary calls release at a given block
fn do_release(vesting_addr: ContractAddress, block: u64) {
    start_cheat_block_number_global(block);
    start_cheat_caller_address(vesting_addr, beneficiary());
    IVestingDispatcher { contract_address: vesting_addr }.release();
    stop_cheat_caller_address(vesting_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// Constructor / getter tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_fields() {
    let (token_addr, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    assert(vesting.get_beneficiary() == beneficiary(), 'wrong beneficiary');
    assert(vesting.get_start()       == START,         'wrong start');
    assert(vesting.get_duration()    == DURATION,      'wrong duration');
    assert(vesting.get_released()    == 0,             'released should be 0');
    assert(vesting.get_balance()     == INITIAL,       'wrong initial balance');
}

// ---------------------------------------------------------------------------
// releasable() tests
// ---------------------------------------------------------------------------
#[test]
fn test_releasable_is_zero_before_start() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    start_cheat_block_number_global(START - 1);
    assert(vesting.releasable() == 0, 'should be 0 before start');
    stop_cheat_block_number_global();
}

#[test]
fn test_releasable_at_start_is_zero() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    // at exactly START, elapsed = 0 so releasable = 0
    start_cheat_block_number_global(START);
    assert(vesting.releasable() == 0, 'should be 0 at start block');
    stop_cheat_block_number_global();
}

#[test]
fn test_releasable_is_proportional_at_quarter() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    start_cheat_block_number_global(START + DURATION / 4);
    assert(vesting.releasable() == INITIAL / 4, 'should be 25%');
    stop_cheat_block_number_global();
}

#[test]
fn test_releasable_is_proportional_at_half() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    start_cheat_block_number_global(START + DURATION / 2);
    assert(vesting.releasable() == INITIAL / 2, 'should be 50%');
    stop_cheat_block_number_global();
}

#[test]
fn test_releasable_is_proportional_at_three_quarters() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    start_cheat_block_number_global(START + (DURATION * 3) / 4);
    assert(vesting.releasable() == (INITIAL * 3) / 4, 'should be 75%');
    stop_cheat_block_number_global();
}

#[test]
fn test_releasable_is_full_at_end() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    start_cheat_block_number_global(END);
    assert(vesting.releasable() == INITIAL, 'should be full at end');
    stop_cheat_block_number_global();
}

#[test]
fn test_releasable_is_full_after_end() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    start_cheat_block_number_global(END + 50);
    assert(vesting.releasable() == INITIAL, 'should be full after end');
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// vested_amount() tests
// ---------------------------------------------------------------------------
#[test]
fn test_vested_amount_before_start() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    start_cheat_block_number_global(START - 1);
    assert(vesting.vested_amount() == 0, 'vested before start = 0');
    stop_cheat_block_number_global();
}

#[test]
fn test_vested_amount_at_half() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    start_cheat_block_number_global(START + DURATION / 2);
    assert(vesting.vested_amount() == INITIAL / 2, 'vested at half = 50%');
    stop_cheat_block_number_global();
}

#[test]
fn test_vested_amount_at_end() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    start_cheat_block_number_global(END);
    assert(vesting.vested_amount() == INITIAL, 'vested at end = full');
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// release() tests
// ---------------------------------------------------------------------------
#[test]
fn test_release_at_halfway() {
    let (token_addr, vesting_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    do_release(vesting_addr, START + DURATION / 2);

    assert(token.balance_of(beneficiary()) == INITIAL / 2, 'wrong amount released');
    assert(vesting.get_released()          == INITIAL / 2, 'wrong released counter');
    assert(vesting.get_balance()           == INITIAL / 2, 'wrong remaining balance');
}

#[test]
fn test_release_full_after_expiry() {
    let (token_addr, vesting_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    do_release(vesting_addr, END + 10);

    assert(token.balance_of(beneficiary()) == INITIAL, 'should receive full amount');
    assert(vesting.get_released()          == INITIAL, 'released counter = full');
    assert(vesting.get_balance()           == 0,       'contract should be empty');
}

#[test]
fn test_release_twice_accumulates_correctly() {
    let (token_addr, vesting_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    // first release at 25%
    do_release(vesting_addr, START + DURATION / 4);
    assert(token.balance_of(beneficiary()) == INITIAL / 4,       '1st release: wrong amount');
    assert(vesting.get_released()          == INITIAL / 4,       '1st release: wrong counter');
    assert(vesting.get_balance()           == (INITIAL * 3) / 4, '1st release: wrong balance');

    // second release at 75% — should only release the delta (50% more)
    do_release(vesting_addr, START + (DURATION * 3) / 4);
    assert(token.balance_of(beneficiary()) == (INITIAL * 3) / 4, '2nd release: wrong amount');
    assert(vesting.get_released()          == (INITIAL * 3) / 4, '2nd release: wrong counter');
    assert(vesting.get_balance()           == INITIAL / 4,        '2nd release: wrong balance');
}

#[test]
fn test_releasable_decreases_after_release() {
    let (_, vesting_addr) = setup();
    let vesting = IVestingDispatcher { contract_address: vesting_addr };

    do_release(vesting_addr, START + DURATION / 2);

    // at the same block, nothing more should be releasable
    start_cheat_block_number_global(START + DURATION / 2);
    assert(vesting.releasable() == 0, 'nothing left at same block');
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// Revert tests
// ---------------------------------------------------------------------------
#[test]
#[should_panic(expected: ('only the beneficiary',))]
fn test_release_reverts_if_not_beneficiary() {
    let (_, vesting_addr) = setup();

    start_cheat_block_number_global(END);
    start_cheat_caller_address(vesting_addr, stranger());
    IVestingDispatcher { contract_address: vesting_addr }.release();
    stop_cheat_caller_address(vesting_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('nothing to release',))]
fn test_release_reverts_before_start() {
    let (_, vesting_addr) = setup();

    do_release(vesting_addr, START - 1);
}

#[test]
#[should_panic(expected: ('nothing to release',))]
fn test_release_reverts_at_start_block() {
    let (_, vesting_addr) = setup();

    // at exactly START, elapsed = 0 → releasable = 0
    do_release(vesting_addr, START);
}

#[test]
fn test_constructor_reverts_if_zero_beneficiary() {
    let token_addr = deploy_token();
    let class = declare("Vesting").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(starknet::contract_address_const::<0>().into()); // zero address
    calldata.append(START.into());
    calldata.append(DURATION.into());
    INITIAL.serialize(ref calldata);
    calldata.append(token_addr.into());

    start_cheat_caller_address_global(deployer());
    let result = class.deploy(@calldata);
    stop_cheat_caller_address_global();

    assert(result.is_err(), 'should fail with zero address');
}