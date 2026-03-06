use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use constant_product_amm::constant_product_amm::{IAMMDispatcher, IAMMDispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn lp() -> ContractAddress       { 'lp'.try_into().unwrap() }       // liquidity provider
fn swapper() -> ContractAddress  { 'swapper'.try_into().unwrap() }
fn stranger() -> ContractAddress { 'stranger'.try_into().unwrap() }

// initial deposit: 1000 t0, 2000 t1  (rate: 1 t0 = 2 t1)
const DEP0: u256 = 1000_u256;
const DEP1: u256 = 2000_u256;

fn deploy_token(recipient: ContractAddress, supply: u256) -> ContractAddress {
    let class = declare("ERC20Mock").unwrap().contract_class();
    let name: ByteArray   = "Token";
    let symbol: ByteArray = "TKN";

    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    supply.serialize(ref calldata);
    calldata.append(recipient.into());

    let (token_addr, _) = class.deploy(@calldata).unwrap();
    token_addr
}

fn deploy_amm(t0: ContractAddress, t1: ContractAddress) -> ContractAddress {
    let class = declare("AMM").unwrap().contract_class();
    let calldata: Array<felt252> = array![t0.into(), t1.into()];
    let (amm_addr, _) = class.deploy(@calldata).unwrap();
    amm_addr
}

fn setup() -> (ContractAddress, ContractAddress, ContractAddress) {
    let t0_addr  = deploy_token(lp(), 1_000_000_u256);
    let t1_addr  = deploy_token(lp(), 1_000_000_u256);
    let amm_addr = deploy_amm(t0_addr, t1_addr);

    // fund swapper
    let t0 = IERC20Dispatcher { contract_address: t0_addr };
    let t1 = IERC20Dispatcher { contract_address: t1_addr };
    start_cheat_caller_address(t0_addr, lp());
    t0.transfer(swapper(), 10_000_u256);
    stop_cheat_caller_address(t0_addr);
    start_cheat_caller_address(t1_addr, lp());
    t1.transfer(swapper(), 10_000_u256);
    stop_cheat_caller_address(t1_addr);

    (t0_addr, t1_addr, amm_addr)
}

// helper: lp approves + deposits DEP0/DEP1
fn do_deposit(
    t0_addr: ContractAddress,
    t1_addr: ContractAddress,
    amm_addr: ContractAddress,
    depositor: ContractAddress,
    x0: u256,
    x1: u256,
) {
    let t0 = IERC20Dispatcher { contract_address: t0_addr };
    let t1 = IERC20Dispatcher { contract_address: t1_addr };

    start_cheat_caller_address(t0_addr, depositor);
    t0.approve(amm_addr, x0);
    stop_cheat_caller_address(t0_addr);

    start_cheat_caller_address(t1_addr, depositor);
    t1.approve(amm_addr, x1);
    stop_cheat_caller_address(t1_addr);

    start_cheat_caller_address(amm_addr, depositor);
    IAMMDispatcher { contract_address: amm_addr }.deposit(x0, x1);
    stop_cheat_caller_address(amm_addr);
}

// ---------------------------------------------------------------------------
// Constructor tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_fields() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    let amm = IAMMDispatcher { contract_address: amm_addr };

    assert(amm.get_t0()     == t0_addr, 'wrong t0');
    assert(amm.get_t1()     == t1_addr, 'wrong t1');
    assert(amm.get_r0()     == 0,       'r0 should be 0');
    assert(amm.get_r1()     == 0,       'r1 should be 0');
    assert(amm.get_supply() == 0,       'supply should be 0');
}

// ---------------------------------------------------------------------------
// deposit() tests
// ---------------------------------------------------------------------------
#[test]
fn test_first_deposit_mints_x0() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    let amm = IAMMDispatcher { contract_address: amm_addr };

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    // first deposit: toMint = x0
    assert(amm.get_r0()          == DEP0, 'wrong r0');
    assert(amm.get_r1()          == DEP1, 'wrong r1');
    assert(amm.get_supply()      == DEP0, 'supply should equal x0');
    assert(amm.get_minted(lp())  == DEP0, 'lp minted should equal x0');
}

#[test]
fn test_second_deposit_maintains_ratio() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    let amm = IAMMDispatcher { contract_address: amm_addr };

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    // second deposit — same ratio: 500 t0, 1000 t1
    do_deposit(t0_addr, t1_addr, amm_addr, lp(), 500_u256, 1000_u256);

    assert(amm.get_r0()     == DEP0 + 500_u256,  'wrong r0 after 2nd deposit');
    assert(amm.get_r1()     == DEP1 + 1000_u256, 'wrong r1 after 2nd deposit');
    assert(amm.get_supply() == DEP0 + 500_u256,  'wrong supply after 2nd deposit');
}

#[test]
#[should_panic(expected: ('amounts must be positive',))]
fn test_deposit_reverts_if_zero_x0() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    do_deposit(t0_addr, t1_addr, amm_addr, lp(), 0, DEP1);
}

#[test]
#[should_panic(expected: ('amounts must be positive',))]
fn test_deposit_reverts_if_zero_x1() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, 0);
}

#[test]
#[should_panic(expected: ('must maintain exchange rate',))]
fn test_deposit_reverts_if_wrong_ratio() {
    let (t0_addr, t1_addr, amm_addr) = setup();

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    // wrong ratio: 500 t0 but only 500 t1 instead of 1000
    do_deposit(t0_addr, t1_addr, amm_addr, lp(), 500_u256, 500_u256);
}

// ---------------------------------------------------------------------------
// redeem() tests
// ---------------------------------------------------------------------------
#[test]
fn test_redeem_returns_proportional_amounts() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    let t0  = IERC20Dispatcher { contract_address: t0_addr };
    let t1  = IERC20Dispatcher { contract_address: t1_addr };
    let amm = IAMMDispatcher { contract_address: amm_addr };

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    let lp_t0_before = t0.balance_of(lp());
    let lp_t1_before = t1.balance_of(lp());

    // redeem half the supply
    let redeem_amount = DEP0 / 2; // 500

    start_cheat_caller_address(amm_addr, lp());
    amm.redeem(redeem_amount);
    stop_cheat_caller_address(amm_addr);

    // should get back 500 t0 and 1000 t1
    assert(t0.balance_of(lp())   == lp_t0_before + 500_u256,  'wrong t0 returned');
    assert(t1.balance_of(lp())   == lp_t1_before + 1000_u256, 'wrong t1 returned');
    assert(amm.get_r0()          == 500_u256,                  'wrong r0 after redeem');
    assert(amm.get_r1()          == 1000_u256,                 'wrong r1 after redeem');
    assert(amm.get_supply()      == 500_u256,                  'wrong supply after redeem');
    assert(amm.get_minted(lp())  == 500_u256,                  'wrong minted after redeem');
}

#[test]
#[should_panic(expected: ('insufficient liquidity tokens',))]
fn test_redeem_reverts_if_insufficient_minted() {
    let (t0_addr, t1_addr, amm_addr) = setup();

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    // stranger has no liquidity tokens
    start_cheat_caller_address(amm_addr, stranger());
    IAMMDispatcher { contract_address: amm_addr }.redeem(100_u256);
    stop_cheat_caller_address(amm_addr);
}

#[test]
#[should_panic(expected: ('x must be less than supply',))]
fn test_redeem_reverts_if_x_equals_supply() {
    let (t0_addr, t1_addr, amm_addr) = setup();

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    // try to redeem entire supply — must be < supply
    start_cheat_caller_address(amm_addr, lp());
    IAMMDispatcher { contract_address: amm_addr }.redeem(DEP0);
    stop_cheat_caller_address(amm_addr);
}

#[test]
#[should_panic(expected: ('x must be positive',))]
fn test_redeem_reverts_if_zero() {
    let (t0_addr, t1_addr, amm_addr) = setup();

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    start_cheat_caller_address(amm_addr, lp());
    IAMMDispatcher { contract_address: amm_addr }.redeem(0);
    stop_cheat_caller_address(amm_addr);
}

// ---------------------------------------------------------------------------
// swap() tests
// ---------------------------------------------------------------------------
#[test]
fn test_swap_t0_for_t1() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    let t0  = IERC20Dispatcher { contract_address: t0_addr };
    let t1  = IERC20Dispatcher { contract_address: t1_addr };
    let amm = IAMMDispatcher { contract_address: amm_addr };

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    // swap 100 t0 for t1
    // x_out = 100 * 2000 / (1000 + 100) = 200000 / 1100 = 181
    let swap_in: u256 = 100_u256;
    let expected_out  = swap_in * DEP1 / (DEP0 + swap_in); // 181

    let swapper_t1_before = t1.balance_of(swapper());

    start_cheat_caller_address(t0_addr, swapper());
    t0.approve(amm_addr, swap_in);
    stop_cheat_caller_address(t0_addr);

    start_cheat_caller_address(amm_addr, swapper());
    amm.swap(t0_addr, swap_in, expected_out);
    stop_cheat_caller_address(amm_addr);

    assert(t1.balance_of(swapper()) == swapper_t1_before + expected_out, 'wrong t1 received');
    assert(amm.get_r0()             == DEP0 + swap_in,                   'wrong r0 after swap');
    assert(amm.get_r1()             == DEP1 - expected_out,              'wrong r1 after swap');
}

#[test]
fn test_swap_t1_for_t0() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    let t0  = IERC20Dispatcher { contract_address: t0_addr };
    let t1  = IERC20Dispatcher { contract_address: t1_addr };
    let amm = IAMMDispatcher { contract_address: amm_addr };

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    // swap 200 t1 for t0
    // x_out = 200 * 1000 / (2000 + 200) = 200000 / 2200 = 90
    let swap_in: u256   = 200_u256;
    let expected_out    = swap_in * DEP0 / (DEP1 + swap_in); // 90

    let swapper_t0_before = t0.balance_of(swapper());

    start_cheat_caller_address(t1_addr, swapper());
    t1.approve(amm_addr, swap_in);
    stop_cheat_caller_address(t1_addr);

    start_cheat_caller_address(amm_addr, swapper());
    amm.swap(t1_addr, swap_in, expected_out);
    stop_cheat_caller_address(amm_addr);

    assert(t0.balance_of(swapper()) == swapper_t0_before + expected_out, 'wrong t0 received');
    assert(amm.get_r0()             == DEP0 - expected_out,              'wrong r0 after swap');
    assert(amm.get_r1()             == DEP1 + swap_in,                   'wrong r1 after swap');
}

#[test]
#[should_panic(expected: ('invalid token address',))]
fn test_swap_reverts_if_invalid_token() {
    let (t0_addr, t1_addr, amm_addr) = setup();

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    start_cheat_caller_address(amm_addr, swapper());
    IAMMDispatcher { contract_address: amm_addr }
        .swap(stranger(), 100_u256, 0);
    stop_cheat_caller_address(amm_addr);
}

#[test]
#[should_panic(expected: ('amounts must be positive',))]
fn test_swap_reverts_if_zero_input() {
    let (t0_addr, t1_addr, amm_addr) = setup();

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    start_cheat_caller_address(amm_addr, swapper());
    IAMMDispatcher { contract_address: amm_addr }
        .swap(t0_addr, 0, 0);
    stop_cheat_caller_address(amm_addr);
}

#[test]
#[should_panic(expected: ('output below minimum',))]
fn test_swap_reverts_if_slippage_too_high() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    let t0 = IERC20Dispatcher { contract_address: t0_addr };

    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    start_cheat_caller_address(t0_addr, swapper());
    t0.approve(amm_addr, 100_u256);
    stop_cheat_caller_address(t0_addr);

    start_cheat_caller_address(amm_addr, swapper());
    // demand more output than possible
    IAMMDispatcher { contract_address: amm_addr }
        .swap(t0_addr, 100_u256, 999_u256);
    stop_cheat_caller_address(amm_addr);
}

// ---------------------------------------------------------------------------
// Integration tests
// ---------------------------------------------------------------------------
#[test]
fn test_deposit_swap_redeem_full_flow() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    let t0  = IERC20Dispatcher { contract_address: t0_addr };
    let t1  = IERC20Dispatcher { contract_address: t1_addr };
    let amm = IAMMDispatcher { contract_address: amm_addr };

    // 1. deposit
    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);
    assert(amm.get_supply() == DEP0, 'wrong supply after deposit');

    // 2. swap 100 t0 → t1
    let swap_in   = 100_u256;
    let x_out     = swap_in * amm.get_r1() / (amm.get_r0() + swap_in);

    start_cheat_caller_address(t0_addr, swapper());
    t0.approve(amm_addr, swap_in);
    stop_cheat_caller_address(t0_addr);

    start_cheat_caller_address(amm_addr, swapper());
    amm.swap(t0_addr, swap_in, x_out);
    stop_cheat_caller_address(amm_addr);

    // 3. redeem half
    let redeem_amount = amm.get_minted(lp()) / 2;
    let r0_before     = amm.get_r0();
    let r1_before     = amm.get_r1();
    let supply_before = amm.get_supply();

    let expected_t0_back = redeem_amount * r0_before / supply_before;
    let expected_t1_back = redeem_amount * r1_before / supply_before;

    let lp_t0_before = t0.balance_of(lp());
    let lp_t1_before = t1.balance_of(lp());

    start_cheat_caller_address(amm_addr, lp());
    amm.redeem(redeem_amount);
    stop_cheat_caller_address(amm_addr);

    assert(t0.balance_of(lp()) == lp_t0_before + expected_t0_back, 'wrong t0 after redeem');
    assert(t1.balance_of(lp()) == lp_t1_before + expected_t1_back, 'wrong t1 after redeem');
    assert(amm.get_supply()    == supply_before - redeem_amount,    'wrong supply after redeem');
}

#[test]
fn test_two_lps_deposit_and_redeem() {
    let (t0_addr, t1_addr, amm_addr) = setup();
    let t0  = IERC20Dispatcher { contract_address: t0_addr };
    let amm = IAMMDispatcher { contract_address: amm_addr };

    // give stranger some tokens
    start_cheat_caller_address(t0_addr, lp());
    t0.transfer(stranger(), 10_000_u256);
    stop_cheat_caller_address(t0_addr);
    let t1 = IERC20Dispatcher { contract_address: t1_addr };
    start_cheat_caller_address(t1_addr, lp());
    t1.transfer(stranger(), 10_000_u256);
    stop_cheat_caller_address(t1_addr);

    // lp deposits first
    do_deposit(t0_addr, t1_addr, amm_addr, lp(), DEP0, DEP1);

    // stranger deposits same ratio
    do_deposit(t0_addr, t1_addr, amm_addr, stranger(), 500_u256, 1000_u256);

    assert(amm.get_minted(lp())       == DEP0,       'lp wrong minted');
    assert(amm.get_minted(stranger())  == 500_u256,   'stranger wrong minted');
    assert(amm.get_supply()           == 1500_u256,   'wrong total supply');

    // stranger redeems their share
    start_cheat_caller_address(amm_addr, stranger());
    amm.redeem(400_u256);
    stop_cheat_caller_address(amm_addr);

    assert(amm.get_minted(stranger()) == 100_u256, 'stranger minted should decrease');
}