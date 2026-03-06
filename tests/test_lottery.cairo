use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
    start_cheat_block_number_global, stop_cheat_block_number_global,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use lottery::lottery::{ILotteryDispatcher, ILotteryDispatcherTrait};
use lottery::lottery::Status;
use core::keccak::compute_keccak_byte_array;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn owner() -> ContractAddress    { 'owner'.try_into().unwrap() }
fn player0() -> ContractAddress  { 'player0'.try_into().unwrap() }
fn player1() -> ContractAddress  { 'player1'.try_into().unwrap() }
fn stranger() -> ContractAddress { 'stranger'.try_into().unwrap() }

// constructor hardcodes 1000 blocks for join and reveal
const START_BLOCK: u64 = 100_u64;
const END_JOIN: u64    = START_BLOCK + 1000_u64;
const END_REVEAL: u64  = END_JOIN + 1000_u64;

const BET: u256 = 100_000_000_000_000_000_u256; // 0.1 > MIN_BET (0.01)

// secrets as ByteArray — length matters for win() formula
// SECRET0 length = 16, SECRET1 length = 16 → 32 % 2 == 0 → player0 wins
// adjust secrets in specific tests to control winner
fn secret0() -> ByteArray { "secret_player_00" } // len = 16
fn secret1() -> ByteArray { "secret_player_11" } // len = 16 → total 32 → player0 wins

fn hash_of(secret: @ByteArray) -> u256 {
    compute_keccak_byte_array(secret)
}

fn deploy_token() -> ContractAddress {
    let class = declare("ERC20Mock").unwrap().contract_class();
    let name: ByteArray   = "TestToken";
    let symbol: ByteArray = "TTK";
    let supply: u256      = 1_000_000_000_000_000_000_000_u256;

    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    supply.serialize(ref calldata);
    calldata.append(player0().into());

    let (token_addr, _) = class.deploy(@calldata).unwrap();

    // fund player1 and stranger
    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, player0());
    token.transfer(player1(), BET * 10);
    token.transfer(stranger(), BET * 10);
    stop_cheat_caller_address(token_addr);

    token_addr
}

fn deploy_lottery(token_addr: ContractAddress) -> ContractAddress {
    let class = declare("Lottery").unwrap().contract_class();

    let calldata: Array<felt252> = array![token_addr.into()];

    start_cheat_block_number_global(START_BLOCK);
    start_cheat_caller_address_global(owner());
    let (lottery_addr, _) = class.deploy(@calldata).unwrap();
    stop_cheat_caller_address_global();
    stop_cheat_block_number_global();

    lottery_addr
}

fn setup() -> (ContractAddress, ContractAddress) {
    let token_addr   = deploy_token();
    let lottery_addr = deploy_lottery(token_addr);
    (token_addr, lottery_addr)
}

// helper: player0 approves + joins
fn do_join0(token_addr: ContractAddress, lottery_addr: ContractAddress) {
    let token = IERC20Dispatcher { contract_address: token_addr };

    start_cheat_caller_address(token_addr, player0());
    token.approve(lottery_addr, BET);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(START_BLOCK + 1);
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.join0(hash_of(@secret0()), BET);
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();
}

// helper: player1 approves + joins
fn do_join1(token_addr: ContractAddress, lottery_addr: ContractAddress) {
    let token = IERC20Dispatcher { contract_address: token_addr };

    start_cheat_caller_address(token_addr, player1());
    token.approve(lottery_addr, BET);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(START_BLOCK + 2);
    start_cheat_caller_address(lottery_addr, player1());
    ILotteryDispatcher { contract_address: lottery_addr }.join1(hash_of(@secret1()), BET);
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();
}

// helper: both players reveal
fn do_reveal(lottery_addr: ContractAddress) {
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    start_cheat_block_number_global(START_BLOCK + 3);

    start_cheat_caller_address(lottery_addr, player0());
    lottery.reveal0(secret0());
    stop_cheat_caller_address(lottery_addr);

    start_cheat_caller_address(lottery_addr, player1());
    lottery.reveal1(secret1());
    stop_cheat_caller_address(lottery_addr);

    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// Constructor tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_fields() {
    let (_, lottery_addr) = setup();
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    assert(lottery.get_owner()      == owner(),        'wrong owner');
    assert(lottery.get_status()     == Status::Join0,  'should be Join0');
    assert(lottery.get_end_join()   == END_JOIN,        'wrong end_join');
    assert(lottery.get_end_reveal() == END_REVEAL,      'wrong end_reveal');
    assert(lottery.get_balance()    == 0,              'balance should be 0');
}

// ---------------------------------------------------------------------------
// join0() tests
// ---------------------------------------------------------------------------
#[test]
fn test_join0_sets_player_and_deposits() {
    let (token_addr, lottery_addr) = setup();
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    do_join0(token_addr, lottery_addr);

    assert(lottery.get_status()     == Status::Join1, 'should be Join1');
    assert(lottery.get_player0()    == player0(),      'wrong player0');
    assert(lottery.get_bet_amount() == BET,            'wrong bet amount');
    assert(lottery.get_balance()    == BET,            'contract should hold bet');
}

#[test]
#[should_panic(expected: ('wrong status',))]
fn test_join0_reverts_if_wrong_status() {
    let (token_addr, lottery_addr) = setup();

    do_join0(token_addr, lottery_addr);
    do_join0(token_addr, lottery_addr); // second join0 should fail
}

#[test]
#[should_panic(expected: ('bet below minimum',))]
fn test_join0_reverts_if_bet_too_low() {
    let (token_addr, lottery_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };

    start_cheat_caller_address(token_addr, player0());
    token.approve(lottery_addr, 1_u256);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(START_BLOCK + 1);
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.join0(hash_of(@secret0()), 1_u256);
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// join1() tests
// ---------------------------------------------------------------------------
#[test]
fn test_join1_sets_player_and_doubles_pot() {
    let (token_addr, lottery_addr) = setup();
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);

    assert(lottery.get_status()  == Status::Reveal0, 'should be Reveal0');
    assert(lottery.get_player1() == player1(),         'wrong player1');
    assert(lottery.get_balance() == BET * 2,           'pot should be doubled');
}

#[test]
#[should_panic(expected: ('hashes must differ',))]
fn test_join1_reverts_if_same_hash() {
    let (token_addr, lottery_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };

    do_join0(token_addr, lottery_addr);

    start_cheat_caller_address(token_addr, player1());
    token.approve(lottery_addr, BET);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(START_BLOCK + 2);
    start_cheat_caller_address(lottery_addr, player1());
    // same hash as player0
    ILotteryDispatcher { contract_address: lottery_addr }.join1(hash_of(@secret0()), BET);
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('amount must equal bet',))]
fn test_join1_reverts_if_wrong_amount() {
    let (token_addr, lottery_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };

    do_join0(token_addr, lottery_addr);

    start_cheat_caller_address(token_addr, player1());
    token.approve(lottery_addr, BET + 1);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(START_BLOCK + 2);
    start_cheat_caller_address(lottery_addr, player1());
    ILotteryDispatcher { contract_address: lottery_addr }.join1(hash_of(@secret1()), BET + 1);
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// redeem0_nojoin1() tests
// ---------------------------------------------------------------------------
#[test]
fn test_redeem0_nojoin1_after_deadline() {
    let (token_addr, lottery_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    do_join0(token_addr, lottery_addr);

    let p0_before = token.balance_of(player0());

    start_cheat_block_number_global(END_JOIN + 1);
    lottery.redeem0_nojoin1();
    stop_cheat_block_number_global();

    assert(lottery.get_status()        == Status::End,     'should be End');
    assert(lottery.get_balance()       == 0,               'contract should be empty');
    assert(token.balance_of(player0()) == p0_before + BET, 'player0 should get bet back');
}

#[test]
#[should_panic(expected: ('deadline not passed',))]
fn test_redeem0_nojoin1_reverts_before_deadline() {
    let (token_addr, lottery_addr) = setup();

    do_join0(token_addr, lottery_addr);

    start_cheat_block_number_global(END_JOIN); // exactly at deadline, not past
    ILotteryDispatcher { contract_address: lottery_addr }.redeem0_nojoin1();
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('wrong status',))]
fn test_redeem0_nojoin1_reverts_if_wrong_status() {
    let (_, lottery_addr) = setup();

    // status is Join0 not Join1
    start_cheat_block_number_global(END_JOIN + 1);
    ILotteryDispatcher { contract_address: lottery_addr }.redeem0_nojoin1();
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// reveal0() tests
// ---------------------------------------------------------------------------
#[test]
fn test_reveal0_transitions_to_reveal1() {
    let (token_addr, lottery_addr) = setup();
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);

    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(lottery_addr, player0());
    lottery.reveal0(secret0());
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();

    assert(lottery.get_status() == Status::Reveal1, 'should be Reveal1');
}

#[test]
#[should_panic(expected: ('wrong sender',))]
fn test_reveal0_reverts_if_not_player0() {
    let (token_addr, lottery_addr) = setup();

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);

    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(lottery_addr, player1()); // player1 tries to reveal0
    ILotteryDispatcher { contract_address: lottery_addr }.reveal0(secret0());
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('secret does not match hash',))]
fn test_reveal0_reverts_if_wrong_secret() {
    let (token_addr, lottery_addr) = setup();

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);

    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.reveal0("wrong_secret");
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// redeem1_noreveal0() tests
// ---------------------------------------------------------------------------
#[test]
fn test_redeem1_noreveal0_after_deadline() {
    let (token_addr, lottery_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);
    // player0 never reveals

    let p1_before = token.balance_of(player1());

    start_cheat_block_number_global(END_REVEAL + 1);
    lottery.redeem1_noreveal0();
    stop_cheat_block_number_global();

    assert(lottery.get_status()        == Status::End,         'should be End');
    assert(lottery.get_balance()       == 0,                   'contract should be empty');
    assert(token.balance_of(player1()) == p1_before + BET * 2, 'player1 should win full pot');
}

#[test]
#[should_panic(expected: ('deadline not passed',))]
fn test_redeem1_noreveal0_reverts_before_deadline() {
    let (token_addr, lottery_addr) = setup();

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);

    start_cheat_block_number_global(END_REVEAL); // exactly at, not past
    ILotteryDispatcher { contract_address: lottery_addr }.redeem1_noreveal0();
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// reveal1() tests
// ---------------------------------------------------------------------------
#[test]
fn test_reveal1_transitions_to_win() {
    let (token_addr, lottery_addr) = setup();
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);
    do_reveal(lottery_addr);

    assert(lottery.get_status() == Status::Win, 'should be Win');
}

#[test]
#[should_panic(expected: ('wrong sender',))]
fn test_reveal1_reverts_if_not_player1() {
    let (token_addr, lottery_addr) = setup();

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);

    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.reveal0(secret0()); // player0 reveals correctly
    stop_cheat_caller_address(lottery_addr);

    // player0 tries to also reveal1
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.reveal1(secret1());
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('secret does not match hash',))]
fn test_reveal1_reverts_if_wrong_secret() {
    let (token_addr, lottery_addr) = setup();

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);

    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.reveal0(secret0());
    stop_cheat_caller_address(lottery_addr);

    start_cheat_caller_address(lottery_addr, player1());
    ILotteryDispatcher { contract_address: lottery_addr }.reveal1("wrong_secret");
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// redeem0_noreveal1() tests
// ---------------------------------------------------------------------------
#[test]
fn test_redeem0_noreveal1_after_deadline() {
    let (token_addr, lottery_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);

    // player0 reveals but player1 does not
    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(lottery_addr, player0());
    lottery.reveal0(secret0());
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();

    let p0_before = token.balance_of(player0());

    start_cheat_block_number_global(END_REVEAL + 1);
    lottery.redeem0_noreveal1();
    stop_cheat_block_number_global();

    assert(lottery.get_status()        == Status::End,         'should be End');
    assert(lottery.get_balance()       == 0,                   'contract should be empty');
    assert(token.balance_of(player0()) == p0_before + BET * 2, 'player0 should win full pot');
}

#[test]
#[should_panic(expected: ('deadline not passed',))]
fn test_redeem0_noreveal1_reverts_before_deadline() {
    let (token_addr, lottery_addr) = setup();

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);

    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.reveal0(secret0());
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();

    start_cheat_block_number_global(END_REVEAL);
    ILotteryDispatcher { contract_address: lottery_addr }.redeem0_noreveal1();
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// win() tests
// ---------------------------------------------------------------------------
#[test]
fn test_win_player0_wins() {
    // secret0 len=16, secret1 len=16 → 32 % 2 == 0 → player0 wins
    let (token_addr, lottery_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);
    do_reveal(lottery_addr);

    let p0_before = token.balance_of(player0());

    start_cheat_block_number_global(START_BLOCK + 4);
    lottery.win();
    stop_cheat_block_number_global();

    assert(lottery.get_status()        == Status::End,         'should be End');
    assert(lottery.get_winner()        == player0(),           'player0 should win');
    assert(lottery.get_balance()       == 0,                   'contract should be empty');
    assert(token.balance_of(player0()) == p0_before + BET * 2, 'player0 should get full pot');
}

#[test]
fn test_win_player1_wins() {
    // use secrets with odd total length → player1 wins
    // secret0 len=16, secret1 len=17 → 33 % 2 == 1 → player1 wins
    let (token_addr, lottery_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let lottery = ILotteryDispatcher { contract_address: lottery_addr };

    let s0: ByteArray = "secret_player_00";  // len = 16
    let s1: ByteArray = "secret_player_111"; // len = 17 → total 33 → odd → player1 wins

    let token_disp = IERC20Dispatcher { contract_address: token_addr };

    // join0
    start_cheat_caller_address(token_addr, player0());
    token_disp.approve(lottery_addr, BET);
    stop_cheat_caller_address(token_addr);
    start_cheat_block_number_global(START_BLOCK + 1);
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.join0(hash_of(@s0), BET);
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();

    // join1
    start_cheat_caller_address(token_addr, player1());
    token_disp.approve(lottery_addr, BET);
    stop_cheat_caller_address(token_addr);
    start_cheat_block_number_global(START_BLOCK + 2);
    start_cheat_caller_address(lottery_addr, player1());
    ILotteryDispatcher { contract_address: lottery_addr }.join1(hash_of(@s1), BET);
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();

    // reveal
    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.reveal0(s0);
    stop_cheat_caller_address(lottery_addr);
    start_cheat_caller_address(lottery_addr, player1());
    ILotteryDispatcher { contract_address: lottery_addr }.reveal1(s1);
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();

    let p1_before = token.balance_of(player1());

    start_cheat_block_number_global(START_BLOCK + 4);
    ILotteryDispatcher { contract_address: lottery_addr }.win();
    stop_cheat_block_number_global();

    assert(lottery.get_winner()        == player1(),           'player1 should win');
    assert(token.balance_of(player1()) == p1_before + BET * 2, 'player1 should get full pot');
}

#[test]
#[should_panic(expected: ('wrong status',))]
fn test_win_reverts_if_wrong_status() {
    let (token_addr, lottery_addr) = setup();

    do_join0(token_addr, lottery_addr);
    do_join1(token_addr, lottery_addr);
    // only player0 reveals — status is Reveal1 not Win
    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(lottery_addr, player0());
    ILotteryDispatcher { contract_address: lottery_addr }.reveal0(secret0());
    stop_cheat_caller_address(lottery_addr);
    stop_cheat_block_number_global();

    ILotteryDispatcher { contract_address: lottery_addr }.win();
}