use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use escrow::escrow::{IEscrowDispatcher, IEscrowDispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn buyer() -> ContractAddress { 'buyer'.try_into().unwrap() }
fn seller() -> ContractAddress { 'seller'.try_into().unwrap() }
fn stranger() -> ContractAddress { 'stranger'.try_into().unwrap() }

const AMOUNT: u256 = 500_u256;

// state constants — mirror the contract
const WAIT_DEPOSIT: u8 = 0;
const WAIT_RECIPIENT: u8 = 1;
const CLOSED: u8 = 2;

fn deploy_token() -> ContractAddress {
    let class = declare("ERC20Mock").unwrap().contract_class();
    let name: ByteArray = "TestToken";
    let symbol: ByteArray = "TTK";
    let supply: u256 = 10_000_u256;

    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    supply.serialize(ref calldata);
    calldata.append(buyer().into()); // mint initial supply to buyer

    let (token_addr, _) = class.deploy(@calldata).unwrap();
    token_addr
}

fn deploy_escrow(token_addr: ContractAddress) -> ContractAddress {
    let class = declare("Escrow").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    AMOUNT.serialize(ref calldata);
    calldata.append(buyer().into());
    calldata.append(seller().into());
    calldata.append(token_addr.into());

    // ✅ seller must be the deployer
    start_cheat_caller_address_global(seller());
    let (escrow_addr, _) = class.deploy(@calldata).unwrap();
    stop_cheat_caller_address_global();

    escrow_addr
}

fn setup() -> (ContractAddress, ContractAddress) {
    let token_addr  = deploy_token();
    let escrow_addr = deploy_escrow(token_addr);
    (token_addr, escrow_addr)
}

// helper: buyer approves + deposits
fn do_deposit(token_addr: ContractAddress, escrow_addr: ContractAddress) {
    let token = IERC20Dispatcher { contract_address: token_addr };

    start_cheat_caller_address(token_addr, buyer());
    token.approve(escrow_addr, AMOUNT);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(escrow_addr, buyer());
    IEscrowDispatcher { contract_address: escrow_addr }.deposit();
    stop_cheat_caller_address(escrow_addr);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_fields() {
    let (token_addr, escrow_addr) = setup();
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    assert(escrow.get_buyer()  == buyer(),     'wrong buyer');
    assert(escrow.get_seller() == seller(),    'wrong seller');
    assert(escrow.get_amount() == AMOUNT,      'wrong amount');
    assert(escrow.get_token()  == token_addr,  'wrong token');
    assert(escrow.get_state()  == WAIT_DEPOSIT,'should be WAIT_DEPOSIT');
}

#[test]
fn test_deposit_moves_to_wait_recipient() {
    let (token_addr, escrow_addr) = setup();
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    do_deposit(token_addr, escrow_addr);

    assert(escrow.get_state() == WAIT_RECIPIENT, 'should be WAIT_RECIPIENT');

    let token = IERC20Dispatcher { contract_address: token_addr };
    assert(token.balance_of(escrow_addr) == AMOUNT, 'escrow should hold funds');
}

#[test]
fn test_pay_sends_funds_to_seller() {
    let (token_addr, escrow_addr) = setup();
    let token  = IERC20Dispatcher { contract_address: token_addr };
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    do_deposit(token_addr, escrow_addr);

    start_cheat_caller_address(escrow_addr, buyer());
    escrow.pay();
    stop_cheat_caller_address(escrow_addr);

    assert(escrow.get_state()            == CLOSED, 'should be CLOSED');
    assert(token.balance_of(seller())    == AMOUNT, 'seller should receive funds');
    assert(token.balance_of(escrow_addr) == 0,      'escrow should be empty');
}

#[test]
fn test_refund_returns_funds_to_buyer() {
    let (token_addr, escrow_addr) = setup();
    let token  = IERC20Dispatcher { contract_address: token_addr };
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    let buyer_balance_before = token.balance_of(buyer());
    do_deposit(token_addr, escrow_addr);

    start_cheat_caller_address(escrow_addr, seller());
    escrow.refund();
    stop_cheat_caller_address(escrow_addr);

    assert(escrow.get_state()            == CLOSED,              'should be CLOSED');
    assert(token.balance_of(buyer())     == buyer_balance_before,'buyer should be refunded');
    assert(token.balance_of(escrow_addr) == 0,                   'escrow should be empty');
}

#[test]
#[should_panic(expected: ('only the buyer',))]
fn test_deposit_reverts_if_not_buyer() {
    let (token_addr, escrow_addr) = setup();
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    start_cheat_caller_address(escrow_addr, stranger());
    escrow.deposit();
    stop_cheat_caller_address(escrow_addr);
}

#[test]
#[should_panic(expected: ('invalid state',))]
fn test_deposit_reverts_if_already_deposited() {
    let (token_addr, escrow_addr) = setup();
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    do_deposit(token_addr, escrow_addr);

    // try to deposit again — state is now WAIT_RECIPIENT
    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, buyer());
    token.approve(escrow_addr, AMOUNT);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(escrow_addr, buyer());
    escrow.deposit();
    stop_cheat_caller_address(escrow_addr);
}

#[test]
#[should_panic(expected: ('invalid state',))]
fn test_pay_reverts_before_deposit() {
    let (_token_addr, escrow_addr) = setup();
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    start_cheat_caller_address(escrow_addr, buyer());
    escrow.pay();
    stop_cheat_caller_address(escrow_addr);
}

#[test]
#[should_panic(expected: ('invalid state',))]
fn test_refund_reverts_before_deposit() {
    let (_token_addr, escrow_addr) = setup();
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    start_cheat_caller_address(escrow_addr, seller());
    escrow.refund();
    stop_cheat_caller_address(escrow_addr);
}

#[test]
#[should_panic(expected: ('only the buyer',))]
fn test_pay_reverts_if_not_buyer() {
    let (token_addr, escrow_addr) = setup();
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    do_deposit(token_addr, escrow_addr);

    start_cheat_caller_address(escrow_addr, stranger());
    escrow.pay();
    stop_cheat_caller_address(escrow_addr);
}

#[test]
#[should_panic(expected: ('only the seller',))]
fn test_refund_reverts_if_not_seller() {
    let (token_addr, escrow_addr) = setup();
    let escrow = IEscrowDispatcher { contract_address: escrow_addr };

    do_deposit(token_addr, escrow_addr);

    start_cheat_caller_address(escrow_addr, stranger());
    escrow.refund();
    stop_cheat_caller_address(escrow_addr);
}

#[test]
#[should_panic(expected: ('creator must be the seller',))]
fn test_constructor_reverts_if_not_seller() {
    let token_addr = deploy_token();
    let class = declare("Escrow").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    AMOUNT.serialize(ref calldata);
    calldata.append(buyer().into());
    calldata.append(seller().into());
    calldata.append(token_addr.into());

    // stranger tries to deploy instead of seller
    start_cheat_caller_address_global(stranger());
    let result = class.deploy(@calldata); // 
    stop_cheat_caller_address_global();

    assert(result.is_err(), 'deploy should have failed');
}
