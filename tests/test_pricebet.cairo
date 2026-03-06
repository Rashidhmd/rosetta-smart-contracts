// tests/test_price_bet.cairo
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
    start_cheat_block_number_global, stop_cheat_block_number_global,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
// ✅ import from price_bet package
use price_bet::price_bet::IPriceBetDispatcher;
use price_bet::price_bet::IPriceBetDispatcherTrait;
use price_bet::oracle::IOracleDispatcher;
use price_bet::oracle::IOracleDispatcherTrait;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn owner() -> ContractAddress    { 'owner'.try_into().unwrap() }
fn player() -> ContractAddress   { 'player'.try_into().unwrap() }
fn stranger() -> ContractAddress { 'stranger'.try_into().unwrap() }

const POT: u256        = 500_u256;
const BET_RATE: u256   = 10_u256;
const DEADLINE: u64    = 10_u64;
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
    calldata.append(owner().into());

    let (token_addr, _) = class.deploy(@calldata).unwrap();

    // send tokens to player and stranger
    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, owner());
    token.transfer(player(), 10_000_u256);
    token.transfer(stranger(), 10_000_u256);
    stop_cheat_caller_address(token_addr);

    token_addr
}

fn deploy_oracle(initial_rate: u256) -> ContractAddress {
    let class = declare("Oracle").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    initial_rate.serialize(ref calldata);

    let (oracle_addr, _) = class.deploy(@calldata).unwrap();
    oracle_addr
}

fn deploy_price_bet(
    token_addr: ContractAddress,
    oracle_addr: ContractAddress,
    bet_rate: u256,
) -> ContractAddress {
    let class = declare("PriceBet").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(oracle_addr.into());
    calldata.append(DEADLINE.into());
    bet_rate.serialize(ref calldata);
    POT.serialize(ref calldata);
    calldata.append(token_addr.into());

    // ✅ cheats active BEFORE precalculate so address is deterministic
    start_cheat_block_number_global(START_BLOCK);
    start_cheat_caller_address_global(owner());

    let bet_addr = class.precalculate_address(@calldata);

    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, owner());
    token.approve(bet_addr, POT);
    stop_cheat_caller_address(token_addr);

    let (deployed_addr, _) = class.deploy(@calldata).unwrap();
    stop_cheat_caller_address_global();
    stop_cheat_block_number_global();

    deployed_addr
}

fn setup() -> (ContractAddress, ContractAddress, ContractAddress) {
    let token_addr  = deploy_token();
    let oracle_addr = deploy_oracle(BET_RATE); // oracle starts at BET_RATE
    let bet_addr    = deploy_price_bet(token_addr, oracle_addr, BET_RATE);
    (token_addr, oracle_addr, bet_addr)
}

// helper: player approves + joins
fn do_join(token_addr: ContractAddress, bet_addr: ContractAddress) {
    let token = IERC20Dispatcher { contract_address: token_addr };

    start_cheat_caller_address(token_addr, player());
    token.approve(bet_addr, POT);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(START_BLOCK + 1);
    start_cheat_caller_address(bet_addr, player());
    IPriceBetDispatcher { contract_address: bet_addr }.join(POT);
    stop_cheat_caller_address(bet_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// Constructor tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_fields() {
    let (token_addr, _, bet_addr) = setup();
    let bet = IPriceBetDispatcher { contract_address: bet_addr };

    assert(bet.get_owner()          == owner(),                'wrong owner');
    assert(bet.get_initial_pot()    == POT,                    'wrong initial pot');
    assert(bet.get_exchange_rate()  == BET_RATE,               'wrong bet rate');
    assert(bet.get_deadline_block() == START_BLOCK + DEADLINE, 'wrong deadline');
    assert(bet.get_balance()        == POT,                    'owner pot should be deposited');
    assert(
        bet.get_player() == starknet::contract_address_const::<0>(),
        'player should be zero'
    );
}

// ---------------------------------------------------------------------------
// Oracle tests
// ---------------------------------------------------------------------------
#[test]
fn test_oracle_initial_rate() {
    let (_, oracle_addr, _) = setup();
    let oracle = IOracleDispatcher { contract_address: oracle_addr };
    assert(oracle.get_exchange_rate() == BET_RATE, 'wrong initial oracle rate');
}

#[test]
fn test_oracle_set_rate() {
    let (_, oracle_addr, _) = setup();
    let oracle = IOracleDispatcher { contract_address: oracle_addr };
    oracle.set_exchange_rate(99_u256);
    assert(oracle.get_exchange_rate() == 99_u256, 'rate should be updated');
}

// ---------------------------------------------------------------------------
// join() tests
// ---------------------------------------------------------------------------
#[test]
fn test_join_sets_player_and_doubles_pot() {
    let (token_addr, _, bet_addr) = setup();
    let bet = IPriceBetDispatcher { contract_address: bet_addr };

    do_join(token_addr, bet_addr);

    assert(bet.get_player()  == player(), 'wrong player');
    assert(bet.get_balance() == POT * 2,  'pot should be doubled');
}

#[test]
#[should_panic(expected: ('amount must equal initial pot',))]
fn test_join_reverts_if_wrong_amount() {
    let (token_addr, _, bet_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };

    start_cheat_caller_address(token_addr, player());
    token.approve(bet_addr, POT + 1);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(START_BLOCK + 1);
    start_cheat_caller_address(bet_addr, player());
    IPriceBetDispatcher { contract_address: bet_addr }.join(POT + 1);
    stop_cheat_caller_address(bet_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('player already joined',))]
fn test_join_reverts_if_already_joined() {
    let (token_addr, _, bet_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };

    do_join(token_addr, bet_addr);

    // stranger tries to join after player
    start_cheat_caller_address(token_addr, stranger());
    token.approve(bet_addr, POT);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(START_BLOCK + 2);
    start_cheat_caller_address(bet_addr, stranger());
    IPriceBetDispatcher { contract_address: bet_addr }.join(POT);
    stop_cheat_caller_address(bet_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// win() tests
// ---------------------------------------------------------------------------
#[test]
fn test_win_when_rate_equals_bet_rate() {
    // oracle rate == BET_RATE → 10 >= 10 → wins
    let (token_addr, _, bet_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };
    let bet   = IPriceBetDispatcher { contract_address: bet_addr };

    do_join(token_addr, bet_addr);

    let player_before = token.balance_of(player());

    start_cheat_block_number_global(START_BLOCK + 2);
    start_cheat_caller_address(bet_addr, player());
    bet.win();
    stop_cheat_caller_address(bet_addr);
    stop_cheat_block_number_global();

    assert(bet.get_balance()          == 0,                       'contract should be empty');
    assert(token.balance_of(player()) == player_before + POT * 2, 'player should win full pot');
}

#[test]
fn test_win_when_rate_above_bet_rate() {
    // set oracle rate above BET_RATE → wins
    let (token_addr, oracle_addr, bet_addr) = setup();
    let token  = IERC20Dispatcher { contract_address: token_addr };
    let oracle = IOracleDispatcher { contract_address: oracle_addr };
    let bet    = IPriceBetDispatcher { contract_address: bet_addr };

    do_join(token_addr, bet_addr);
    oracle.set_exchange_rate(BET_RATE + 5);

    let player_before = token.balance_of(player());

    start_cheat_block_number_global(START_BLOCK + 2);
    start_cheat_caller_address(bet_addr, player());
    bet.win();
    stop_cheat_caller_address(bet_addr);
    stop_cheat_block_number_global();

    assert(token.balance_of(player()) == player_before + POT * 2, 'player should win');
}

#[test]
#[should_panic(expected: ('you lost the bet',))]
fn test_win_reverts_if_rate_below_bet_rate() {
    // set oracle below BET_RATE → loses
    let (token_addr, oracle_addr, bet_addr) = setup();
    let oracle = IOracleDispatcher { contract_address: oracle_addr };

    do_join(token_addr, bet_addr);
    oracle.set_exchange_rate(BET_RATE - 1);

    start_cheat_block_number_global(START_BLOCK + 2);
    start_cheat_caller_address(bet_addr, player());
    IPriceBetDispatcher { contract_address: bet_addr }.win();
    stop_cheat_caller_address(bet_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('deadline expired',))]
fn test_win_reverts_after_deadline() {
    let (token_addr, _, bet_addr) = setup();

    do_join(token_addr, bet_addr);

    start_cheat_block_number_global(START_BLOCK + DEADLINE);
    start_cheat_caller_address(bet_addr, player());
    IPriceBetDispatcher { contract_address: bet_addr }.win();
    stop_cheat_caller_address(bet_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('only the player can win',))]
fn test_win_reverts_if_not_player() {
    let (token_addr, _, bet_addr) = setup();

    do_join(token_addr, bet_addr);

    start_cheat_block_number_global(START_BLOCK + 2);
    start_cheat_caller_address(bet_addr, stranger());
    IPriceBetDispatcher { contract_address: bet_addr }.win();
    stop_cheat_caller_address(bet_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// timeout() tests
// ---------------------------------------------------------------------------
#[test]
fn test_timeout_returns_full_pot_to_owner() {
    let (token_addr, _, bet_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };
    let bet   = IPriceBetDispatcher { contract_address: bet_addr };

    do_join(token_addr, bet_addr);

    let owner_before = token.balance_of(owner());

    start_cheat_block_number_global(START_BLOCK + DEADLINE);
    bet.timeout();
    stop_cheat_block_number_global();

    assert(bet.get_balance()         == 0,                      'contract should be empty');
    assert(token.balance_of(owner()) == owner_before + POT * 2, 'owner should get full pot');
}

#[test]
fn test_timeout_without_player_returns_initial_pot() {
    let (token_addr, _, bet_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };
    let bet   = IPriceBetDispatcher { contract_address: bet_addr };

    let owner_before = token.balance_of(owner());

    start_cheat_block_number_global(START_BLOCK + DEADLINE);
    bet.timeout();
    stop_cheat_block_number_global();

    assert(bet.get_balance()         == 0,                  'contract should be empty');
    assert(token.balance_of(owner()) == owner_before + POT, 'owner gets initial pot back');
}

#[test]
#[should_panic(expected: ('deadline not expired',))]
fn test_timeout_reverts_before_deadline() {
    let (token_addr, _, bet_addr) = setup();

    do_join(token_addr, bet_addr);

    start_cheat_block_number_global(START_BLOCK + DEADLINE - 1);
    IPriceBetDispatcher { contract_address: bet_addr }.timeout();
    stop_cheat_block_number_global();
}