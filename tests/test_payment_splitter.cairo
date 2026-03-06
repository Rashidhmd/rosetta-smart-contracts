use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use payment_splitter::payment_splitter::{IPaymentSplitterDispatcher, IPaymentSplitterDispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn sender() -> ContractAddress  { 'sender'.try_into().unwrap() }
fn payee1() -> ContractAddress  { 'payee1'.try_into().unwrap() }
fn payee2() -> ContractAddress  { 'payee2'.try_into().unwrap() }
fn payee3() -> ContractAddress  { 'payee3'.try_into().unwrap() }
fn stranger() -> ContractAddress { 'stranger'.try_into().unwrap() }

const DEPOSIT: u256 = 1000_u256;

fn deploy_token() -> ContractAddress {
    let class = declare("ERC20Mock").unwrap().contract_class();
    let name: ByteArray   = "TestToken";
    let symbol: ByteArray = "TTK";
    let supply: u256      = 100_000_u256;

    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    supply.serialize(ref calldata);
    calldata.append(sender().into());

    let (token_addr, _) = class.deploy(@calldata).unwrap();
    token_addr
}

/// Deploy with equal shares: payee1=1, payee2=1, payee3=1
fn deploy_equal(token_addr: ContractAddress) -> ContractAddress {
    let class = declare("PaymentSplitter").unwrap().contract_class();

    // payees array: [payee1, payee2, payee3]
    let mut payees: Array<felt252> = array![3]; // length prefix
    payees.append(payee1().into());
    payees.append(payee2().into());
    payees.append(payee3().into());

    // shares array: [1, 1, 1]
    let mut shares: Array<felt252> = array![3]; // length prefix
    let one: u256 = 1;
    one.serialize(ref shares);
    one.serialize(ref shares);
    one.serialize(ref shares);

    let mut calldata: Array<felt252> = array![];
    // append payees span
    calldata.append(3); // array length
    calldata.append(payee1().into());
    calldata.append(payee2().into());
    calldata.append(payee3().into());
    // append shares span
    calldata.append(3); // array length
    one.serialize(ref calldata);
    one.serialize(ref calldata);
    one.serialize(ref calldata);
    // token
    calldata.append(token_addr.into());

    let (addr, _) = class.deploy(@calldata).unwrap();
    addr
}

/// Deploy with unequal shares: payee1=1, payee2=2, payee3=3  (total=6)
fn deploy_unequal(token_addr: ContractAddress) -> ContractAddress {
    let class = declare("PaymentSplitter").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(3);
    calldata.append(payee1().into());
    calldata.append(payee2().into());
    calldata.append(payee3().into());

    calldata.append(3);
    let s1: u256 = 1; s1.serialize(ref calldata);
    let s2: u256 = 2; s2.serialize(ref calldata);
    let s3: u256 = 3; s3.serialize(ref calldata);

    calldata.append(token_addr.into());

    let (addr, _) = class.deploy(@calldata).unwrap();
    addr
}

// helper: sender approves + deposits
fn do_receive(token_addr: ContractAddress, ps_addr: ContractAddress, amount: u256) {
    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, sender());
    token.approve(ps_addr, amount);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(ps_addr, sender());
    IPaymentSplitterDispatcher { contract_address: ps_addr }.receive(amount);
    stop_cheat_caller_address(ps_addr);
}

// ---------------------------------------------------------------------------
// Constructor tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_total_shares_equal() {
    let token_addr = deploy_token();
    let ps = IPaymentSplitterDispatcher { contract_address: deploy_equal(token_addr) };

    assert(ps.total_shares()     == 3,      'total shares should be 3');
    assert(ps.total_released()   == 0,      'total released should be 0');
    assert(ps.shares(payee1())   == 1,      'payee1 should have 1 share');
    assert(ps.shares(payee2())   == 1,      'payee2 should have 1 share');
    assert(ps.shares(payee3())   == 1,      'payee3 should have 1 share');
    assert(ps.payee(0)           == payee1(),'payee 0 wrong');
    assert(ps.payee(1)           == payee2(),'payee 1 wrong');
    assert(ps.payee(2)           == payee3(),'payee 2 wrong');
}

#[test]
fn test_constructor_sets_total_shares_unequal() {
    let token_addr = deploy_token();
    let ps = IPaymentSplitterDispatcher { contract_address: deploy_unequal(token_addr) };

    assert(ps.total_shares()   == 6, 'total shares should be 6');
    assert(ps.shares(payee1()) == 1, 'payee1 should have 1 share');
    assert(ps.shares(payee2()) == 2, 'payee2 should have 2 shares');
    assert(ps.shares(payee3()) == 3, 'payee3 should have 3 shares');
}

// ---------------------------------------------------------------------------
// receive() tests
// ---------------------------------------------------------------------------
#[test]
fn test_receive_increases_balance() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    do_receive(token_addr, ps_addr, DEPOSIT);

    assert(ps.get_balance() == DEPOSIT, 'wrong balance after receive');
}

#[test]
fn test_receive_multiple_deposits() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    do_receive(token_addr, ps_addr, 400_u256);
    do_receive(token_addr, ps_addr, 600_u256);

    assert(ps.get_balance() == 1000_u256, 'wrong accumulated balance');
}

// ---------------------------------------------------------------------------
// releasable() tests
// ---------------------------------------------------------------------------
#[test]
fn test_releasable_equal_shares() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    do_receive(token_addr, ps_addr, 900_u256); // 300 each

    assert(ps.releasable(payee1()) == 300_u256, 'payee1 should get 300');
    assert(ps.releasable(payee2()) == 300_u256, 'payee2 should get 300');
    assert(ps.releasable(payee3()) == 300_u256, 'payee3 should get 300');
}

#[test]
fn test_releasable_unequal_shares() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_unequal(token_addr);
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    // total=6 shares, deposit 600 → payee1=100, payee2=200, payee3=300
    do_receive(token_addr, ps_addr, 600_u256);

    assert(ps.releasable(payee1()) == 100_u256, 'payee1 should get 100');
    assert(ps.releasable(payee2()) == 200_u256, 'payee2 should get 200');
    assert(ps.releasable(payee3()) == 300_u256, 'payee3 should get 300');
}

#[test]
fn test_releasable_is_zero_before_deposit() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    assert(ps.releasable(payee1()) == 0, 'should be 0 before deposit');
}

// ---------------------------------------------------------------------------
// release() tests
// ---------------------------------------------------------------------------
#[test]
fn test_release_equal_shares() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);
    let token      = IERC20Dispatcher { contract_address: token_addr };
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    do_receive(token_addr, ps_addr, 900_u256);

    let p1_before = token.balance_of(payee1());
    let p2_before = token.balance_of(payee2());
    let p3_before = token.balance_of(payee3());

    // anyone can call release for any account
    ps.release(payee1());
    ps.release(payee2());
    ps.release(payee3());

    assert(token.balance_of(payee1()) == p1_before + 300_u256, 'payee1 wrong amount');
    assert(token.balance_of(payee2()) == p2_before + 300_u256, 'payee2 wrong amount');
    assert(token.balance_of(payee3()) == p3_before + 300_u256, 'payee3 wrong amount');
    assert(ps.get_balance()           == 0,                    'contract should be empty');
    assert(ps.total_released()        == 900_u256,             'wrong total released');
}

#[test]
fn test_release_unequal_shares() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_unequal(token_addr);
    let token      = IERC20Dispatcher { contract_address: token_addr };
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    do_receive(token_addr, ps_addr, 600_u256);

    ps.release(payee1());
    ps.release(payee2());
    ps.release(payee3());

    assert(token.balance_of(payee1()) == 100_u256, 'payee1 wrong amount');
    assert(token.balance_of(payee2()) == 200_u256, 'payee2 wrong amount');
    assert(token.balance_of(payee3()) == 300_u256, 'payee3 wrong amount');
    assert(ps.get_balance()           == 0,         'contract should be empty');
}

#[test]
fn test_release_updates_released_counter() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    do_receive(token_addr, ps_addr, 900_u256);
    ps.release(payee1());

    assert(ps.released(payee1())  == 300_u256, 'payee1 released wrong');
    assert(ps.released(payee2())  == 0,         'payee2 released should be 0');
    assert(ps.total_released()    == 300_u256, 'total released wrong');
}

#[test]
fn test_release_partial_then_more_deposit() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);
    let token      = IERC20Dispatcher { contract_address: token_addr };
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    // first deposit + release payee1
    do_receive(token_addr, ps_addr, 900_u256);
    ps.release(payee1());

    // second deposit — payee1 should only get share of the new deposit
    do_receive(token_addr, ps_addr, 300_u256);

    let p1_before = token.balance_of(payee1());
    ps.release(payee1());

    // payee1 should receive 1/3 of 300 = 100 more
    assert(token.balance_of(payee1()) == p1_before + 100_u256, 'payee1 wrong second release');
    assert(ps.released(payee1())      == 400_u256,             'wrong total released payee1');
}

#[test]
fn test_anyone_can_call_release() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);
    let token      = IERC20Dispatcher { contract_address: token_addr };
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    do_receive(token_addr, ps_addr, 900_u256);

    // stranger calls release on behalf of payee1
    start_cheat_caller_address(ps_addr, stranger());
    ps.release(payee1());
    stop_cheat_caller_address(ps_addr);

    assert(token.balance_of(payee1()) == 300_u256, 'payee1 should have received');
}

// ---------------------------------------------------------------------------
// Revert tests
// ---------------------------------------------------------------------------
#[test]
#[should_panic(expected: ('account has no shares',))]
fn test_release_reverts_if_no_shares() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);

    do_receive(token_addr, ps_addr, 900_u256);

    IPaymentSplitterDispatcher { contract_address: ps_addr }.release(stranger());
}

#[test]
#[should_panic(expected: ('account not due payment',))]
fn test_release_reverts_if_nothing_due() {
    let token_addr = deploy_token();
    let ps_addr    = deploy_equal(token_addr);
    let ps         = IPaymentSplitterDispatcher { contract_address: ps_addr };

    do_receive(token_addr, ps_addr, 900_u256);
    ps.release(payee1());

    // no new deposits — nothing more due
    ps.release(payee1());
}

#[test]
fn test_constructor_reverts_if_length_mismatch() {
    let token_addr = deploy_token();
    let class = declare("PaymentSplitter").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    // 2 payees but 3 shares
    calldata.append(2);
    calldata.append(payee1().into());
    calldata.append(payee2().into());

    calldata.append(3);
    let s: u256 = 1;
    s.serialize(ref calldata);
    s.serialize(ref calldata);
    s.serialize(ref calldata);

    calldata.append(token_addr.into());

    let result = class.deploy(@calldata);
    assert(result.is_err(), 'should fail: length mismatch');
}

#[test]
fn test_constructor_reverts_if_no_payees() {
    let token_addr = deploy_token();
    let class = declare("PaymentSplitter").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(0); // empty payees
    calldata.append(0); // empty shares
    calldata.append(token_addr.into());

    let result = class.deploy(@calldata);
    assert(result.is_err(), 'should fail: no payees');
}