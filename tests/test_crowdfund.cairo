use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
    start_cheat_block_number_global, stop_cheat_block_number_global,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use crowdfund::crowdfund::{ICrowdfundDispatcher, ICrowdfundDispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn receiver() -> ContractAddress  { 'receiver'.try_into().unwrap() }
fn donor1() -> ContractAddress    { 'donor1'.try_into().unwrap() }
fn donor2() -> ContractAddress    { 'donor2'.try_into().unwrap() }
fn stranger() -> ContractAddress  { 'stranger'.try_into().unwrap() }

const GOAL: u256       = 1000_u256;
const END_BLOCK: u64   = 100_u64;
const START_BLOCK: u64 = 50_u64;

fn deploy_token() -> ContractAddress {
    let class = declare("ERC20Mock").unwrap().contract_class();
    let name: ByteArray   = "TestToken";
    let symbol: ByteArray = "TTK";
    let supply: u256      = 100_000_u256;

    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    supply.serialize(ref calldata);
    calldata.append(donor1().into()); // mint all to donor1

    let (token_addr, _) = class.deploy(@calldata).unwrap();

    // send some to donor2
    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, donor1());
    token.transfer(donor2(), 10_000_u256);
    stop_cheat_caller_address(token_addr);

    token_addr
}

fn deploy_crowdfund(token_addr: ContractAddress) -> ContractAddress {
    let class = declare("Crowdfund").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(receiver().into());
    calldata.append(END_BLOCK.into());
    GOAL.serialize(ref calldata);
    calldata.append(token_addr.into());

    let (cf_addr, _) = class.deploy(@calldata).unwrap();
    cf_addr
}

fn setup() -> (ContractAddress, ContractAddress) {
    let token_addr = deploy_token();
    let cf_addr    = deploy_crowdfund(token_addr);
    (token_addr, cf_addr)
}

// helper: approve + donate
fn do_donate(
    token_addr: ContractAddress,
    cf_addr: ContractAddress,
    donor: ContractAddress,
    amount: u256,
    block: u64,
) {
    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, donor);
    token.approve(cf_addr, amount);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(block);
    start_cheat_caller_address(cf_addr, donor);
    ICrowdfundDispatcher { contract_address: cf_addr }.donate(amount);
    stop_cheat_caller_address(cf_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_fields() {
    let (token_addr, cf_addr) = setup();
    let cf = ICrowdfundDispatcher { contract_address: cf_addr };

    assert(cf.get_receiver()  == receiver(),  'wrong receiver');
    assert(cf.get_goal()      == GOAL,        'wrong goal');
    assert(cf.get_end_block() == END_BLOCK,   'wrong end block');
    assert(cf.get_balance()   == 0,           'balance should be 0');
}

#[test]
fn test_donate_accumulates_balance() {
    let (token_addr, cf_addr) = setup();
    let cf = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 400_u256, START_BLOCK);
    do_donate(token_addr, cf_addr, donor2(), 600_u256, START_BLOCK);

    assert(cf.get_balance()              == 1000_u256, 'wrong total balance');
    assert(cf.get_donation(donor1())     == 400_u256,  'wrong donor1 donation');
    assert(cf.get_donation(donor2())     == 600_u256,  'wrong donor2 donation');
}

#[test]
fn test_withdraw_succeeds_when_goal_reached() {
    let (token_addr, cf_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };
    let cf    = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 1000_u256, START_BLOCK);

    let balance_before = token.balance_of(receiver());

    // after deadline
    start_cheat_block_number_global(END_BLOCK);
    start_cheat_caller_address(cf_addr, receiver());
    cf.withdraw();
    stop_cheat_caller_address(cf_addr);
    stop_cheat_block_number_global();

    assert(cf.get_balance()             == 0,                            'contract should be empty');
    assert(token.balance_of(receiver()) == balance_before + 1000_u256,  'receiver not paid');
}

#[test]
fn test_reclaim_succeeds_when_goal_not_reached() {
    let (token_addr, cf_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };
    let cf    = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 400_u256, START_BLOCK);
    do_donate(token_addr, cf_addr, donor2(), 300_u256, START_BLOCK);

    let donor1_before = token.balance_of(donor1());
    let donor2_before = token.balance_of(donor2());

    // after deadline, goal not reached (700 < 1000)
    start_cheat_block_number_global(END_BLOCK);

    start_cheat_caller_address(cf_addr, donor1());
    cf.reclaim();
    stop_cheat_caller_address(cf_addr);

    start_cheat_caller_address(cf_addr, donor2());
    cf.reclaim();
    stop_cheat_caller_address(cf_addr);

    stop_cheat_block_number_global();

    assert(token.balance_of(donor1()) == donor1_before + 400_u256, 'donor1 not refunded');
    assert(token.balance_of(donor2()) == donor2_before + 300_u256, 'donor2 not refunded');
    assert(cf.get_balance()           == 0,                        'contract should be empty');
    assert(cf.get_donation(donor1())  == 0,                        'donor1 map not cleared');
    assert(cf.get_donation(donor2())  == 0,                        'donor2 map not cleared');
}

#[test]
fn test_donate_multiple_times_accumulates() {
    let (token_addr, cf_addr) = setup();
    let cf = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 200_u256, START_BLOCK);
    do_donate(token_addr, cf_addr, donor1(), 300_u256, START_BLOCK + 1);

    assert(cf.get_donation(donor1()) == 500_u256, 'donations should accumulate');
}

#[test]
#[should_panic(expected: ('deadline has passed',))]
fn test_donate_reverts_after_deadline() {
    let (token_addr, cf_addr) = setup();

    // donate after deadline
    do_donate(token_addr, cf_addr, donor1(), 500_u256, END_BLOCK + 1);
}

#[test]
#[should_panic(expected: ('deadline not reached',))]
fn test_withdraw_reverts_before_deadline() {
    let (token_addr, cf_addr) = setup();
    let cf = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 1000_u256, START_BLOCK);

    start_cheat_block_number_global(START_BLOCK);
    start_cheat_caller_address(cf_addr, receiver());
    cf.withdraw();
    stop_cheat_caller_address(cf_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('goal not reached',))]
fn test_withdraw_reverts_if_goal_not_reached() {
    let (token_addr, cf_addr) = setup();
    let cf = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 500_u256, START_BLOCK);

    start_cheat_block_number_global(END_BLOCK);
    start_cheat_caller_address(cf_addr, receiver());
    cf.withdraw();
    stop_cheat_caller_address(cf_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('only the receiver',))]
fn test_withdraw_reverts_if_not_receiver() {
    let (token_addr, cf_addr) = setup();
    let cf = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 1000_u256, START_BLOCK);

    start_cheat_block_number_global(END_BLOCK);
    start_cheat_caller_address(cf_addr, stranger());
    cf.withdraw();
    stop_cheat_caller_address(cf_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('deadline not reached',))]
fn test_reclaim_reverts_before_deadline() {
    let (token_addr, cf_addr) = setup();
    let cf = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 100_u256, START_BLOCK);

    start_cheat_block_number_global(START_BLOCK);
    start_cheat_caller_address(cf_addr, donor1());
    cf.reclaim();
    stop_cheat_caller_address(cf_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('goal was reached',))]
fn test_reclaim_reverts_if_goal_reached() {
    let (token_addr, cf_addr) = setup();
    let cf = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 1000_u256, START_BLOCK);

    start_cheat_block_number_global(END_BLOCK);
    start_cheat_caller_address(cf_addr, donor1());
    cf.reclaim();
    stop_cheat_caller_address(cf_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('nothing to reclaim',))]
fn test_reclaim_reverts_if_no_donation() {
    let (token_addr, cf_addr) = setup();
    let cf = ICrowdfundDispatcher { contract_address: cf_addr };

    do_donate(token_addr, cf_addr, donor1(), 100_u256, START_BLOCK);

    start_cheat_block_number_global(END_BLOCK);
    start_cheat_caller_address(cf_addr, stranger()); // stranger never donated
    cf.reclaim();
    stop_cheat_caller_address(cf_addr);
    stop_cheat_block_number_global();
}