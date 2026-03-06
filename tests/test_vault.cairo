use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
    start_cheat_block_number_global, stop_cheat_block_number_global,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use vault::vault::{IVaultDispatcher, IVaultDispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn owner() -> ContractAddress    { 'owner'.try_into().unwrap() }
fn recovery() -> ContractAddress { 'recovery'.try_into().unwrap() }
fn receiver() -> ContractAddress { 'receiver'.try_into().unwrap() }
fn stranger() -> ContractAddress { 'stranger'.try_into().unwrap() }

const WAIT_TIME: u64   = 10_u64;
const START_BLOCK: u64 = 50_u64;
const DEPOSIT: u256    = 1000_u256;
const WITHDRAW: u256   = 500_u256;

const IDLE: u8 = 0;
const REQ: u8  = 1;

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
    token_addr
}

fn deploy_vault(token_addr: ContractAddress) -> ContractAddress {
    let class = declare("Vault").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(recovery().into());
    calldata.append(WAIT_TIME.into());
    calldata.append(token_addr.into());

    start_cheat_caller_address_global(owner());
    let (vault_addr, _) = class.deploy(@calldata).unwrap();
    stop_cheat_caller_address_global();

    vault_addr
}

fn setup() -> (ContractAddress, ContractAddress) {
    let token_addr = deploy_token();
    let vault_addr = deploy_vault(token_addr);
    (token_addr, vault_addr)
}

// helper: owner deposits into vault
fn do_deposit(token_addr: ContractAddress, vault_addr: ContractAddress, amount: u256) {
    let token = IERC20Dispatcher { contract_address: token_addr };

    start_cheat_caller_address(token_addr, owner());
    token.approve(vault_addr, amount);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(vault_addr, owner());
    IVaultDispatcher { contract_address: vault_addr }.receive(amount);
    stop_cheat_caller_address(vault_addr);
}

// helper: owner issues withdraw request
fn do_withdraw_request(vault_addr: ContractAddress, block: u64) {
    start_cheat_block_number_global(block);
    start_cheat_caller_address(vault_addr, owner());
    IVaultDispatcher { contract_address: vault_addr }.withdraw(receiver(), WITHDRAW);
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_fields() {
    let (_token_addr, vault_addr) = setup();
    let vault = IVaultDispatcher { contract_address: vault_addr };

    assert(vault.get_owner()     == owner(),    'wrong owner');
    assert(vault.get_recovery()  == recovery(), 'wrong recovery');
    assert(vault.get_wait_time() == WAIT_TIME,  'wrong wait time');
    assert(vault.get_state()     == IDLE,       'should be IDLE');
    assert(vault.get_balance()   == 0,          'balance should be 0');
}

#[test]
fn test_deposit_increases_balance() {
    let (token_addr, vault_addr) = setup();
    let vault = IVaultDispatcher { contract_address: vault_addr };

    do_deposit(token_addr, vault_addr, DEPOSIT);

    assert(vault.get_balance() == DEPOSIT, 'wrong balance');
}

#[test]
fn test_anyone_can_deposit() {
    let (token_addr, vault_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };
    let vault = IVaultDispatcher { contract_address: vault_addr };

    // transfer some tokens to stranger
    start_cheat_caller_address(token_addr, owner());
    token.transfer(stranger(), 500_u256);
    stop_cheat_caller_address(token_addr);

    // stranger deposits
    start_cheat_caller_address(token_addr, stranger());
    token.approve(vault_addr, 500_u256);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(vault_addr, stranger());
    vault.receive(500_u256);
    stop_cheat_caller_address(vault_addr);

    assert(vault.get_balance() == 500_u256, 'stranger deposit failed');
}

#[test]
fn test_withdraw_transitions_to_req() {
    let (token_addr, vault_addr) = setup();
    let vault = IVaultDispatcher { contract_address: vault_addr };

    do_deposit(token_addr, vault_addr, DEPOSIT);
    do_withdraw_request(vault_addr, START_BLOCK);

    assert(vault.get_state()           == REQ,      'should be REQ');
    assert(vault.get_pending_receiver() == receiver(), 'wrong pending receiver');
    assert(vault.get_pending_amount()  == WITHDRAW,  'wrong pending amount');
    assert(vault.get_request_block()   == START_BLOCK,'wrong request block');
}

#[test]
fn test_finalize_after_wait_time() {
    let (token_addr, vault_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };
    let vault = IVaultDispatcher { contract_address: vault_addr };

    do_deposit(token_addr, vault_addr, DEPOSIT);
    do_withdraw_request(vault_addr, START_BLOCK);

    let receiver_balance_before = token.balance_of(receiver());

    // finalize after wait time has elapsed
    start_cheat_block_number_global(START_BLOCK + WAIT_TIME);
    start_cheat_caller_address(vault_addr, owner());
    vault.finalize();
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();

    assert(vault.get_state()            == IDLE,                             'should be IDLE');
    assert(vault.get_balance()          == DEPOSIT - WITHDRAW,               'wrong vault balance');
    assert(token.balance_of(receiver()) == receiver_balance_before + WITHDRAW,'receiver not paid');
}

#[test]
fn test_cancel_resets_to_idle() {
    let (token_addr, vault_addr) = setup();
    let vault = IVaultDispatcher { contract_address: vault_addr };

    do_deposit(token_addr, vault_addr, DEPOSIT);
    do_withdraw_request(vault_addr, START_BLOCK);

    // recovery cancels during wait period
    start_cheat_block_number_global(START_BLOCK + WAIT_TIME - 1);
    start_cheat_caller_address(vault_addr, recovery());
    vault.cancel();
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();

    // vault is back to idle, funds untouched
    assert(vault.get_state()   == IDLE,    'should be IDLE after cancel');
    assert(vault.get_balance() == DEPOSIT, 'funds should be untouched');
}

#[test]
fn test_owner_can_request_again_after_cancel() {
    let (token_addr, vault_addr) = setup();
    let vault = IVaultDispatcher { contract_address: vault_addr };

    do_deposit(token_addr, vault_addr, DEPOSIT);
    do_withdraw_request(vault_addr, START_BLOCK);

    start_cheat_caller_address(vault_addr, recovery());
    start_cheat_block_number_global(START_BLOCK + 1);
    vault.cancel();
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();

    // owner can issue a new request after cancel
    do_withdraw_request(vault_addr, START_BLOCK + 2);
    assert(vault.get_state() == REQ, 'should be REQ again');
}

#[test]
#[should_panic(expected: ('only the owner',))]
fn test_withdraw_reverts_if_not_owner() {
    let (token_addr, vault_addr) = setup();

    do_deposit(token_addr, vault_addr, DEPOSIT);

    start_cheat_block_number_global(START_BLOCK);
    start_cheat_caller_address(vault_addr, stranger());
    IVaultDispatcher { contract_address: vault_addr }.withdraw(receiver(), WITHDRAW);
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('state must be idle',))]
fn test_withdraw_reverts_if_already_pending() {
    let (token_addr, vault_addr) = setup();

    do_deposit(token_addr, vault_addr, DEPOSIT);
    do_withdraw_request(vault_addr, START_BLOCK);

    // try to issue another request while one is pending
    do_withdraw_request(vault_addr, START_BLOCK + 1);
}

#[test]
#[should_panic(expected: ('insufficient balance',))]
fn test_withdraw_reverts_if_amount_too_high() {
    let (token_addr, vault_addr) = setup();

    do_deposit(token_addr, vault_addr, DEPOSIT);

    start_cheat_block_number_global(START_BLOCK);
    start_cheat_caller_address(vault_addr, owner());
    IVaultDispatcher { contract_address: vault_addr }.withdraw(receiver(), DEPOSIT + 1);
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('only the owner',))]
fn test_finalize_reverts_if_not_owner() {
    let (token_addr, vault_addr) = setup();

    do_deposit(token_addr, vault_addr, DEPOSIT);
    do_withdraw_request(vault_addr, START_BLOCK);

    start_cheat_block_number_global(START_BLOCK + WAIT_TIME);
    start_cheat_caller_address(vault_addr, stranger());
    IVaultDispatcher { contract_address: vault_addr }.finalize();
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('wait time not elapsed',))]
fn test_finalize_reverts_before_wait_time() {
    let (token_addr, vault_addr) = setup();

    do_deposit(token_addr, vault_addr, DEPOSIT);
    do_withdraw_request(vault_addr, START_BLOCK);

    // one block before wait time elapses
    start_cheat_block_number_global(START_BLOCK + WAIT_TIME - 1);
    start_cheat_caller_address(vault_addr, owner());
    IVaultDispatcher { contract_address: vault_addr }.finalize();
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('no pending request',))]
fn test_finalize_reverts_if_no_request() {
    let (token_addr, vault_addr) = setup();

    do_deposit(token_addr, vault_addr, DEPOSIT);

    // finalize without a pending request
    start_cheat_block_number_global(START_BLOCK + WAIT_TIME);
    start_cheat_caller_address(vault_addr, owner());
    IVaultDispatcher { contract_address: vault_addr }.finalize();
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('only the recovery key',))]
fn test_cancel_reverts_if_not_recovery() {
    let (token_addr, vault_addr) = setup();

    do_deposit(token_addr, vault_addr, DEPOSIT);
    do_withdraw_request(vault_addr, START_BLOCK);

    start_cheat_block_number_global(START_BLOCK + 1);
    start_cheat_caller_address(vault_addr, stranger());
    IVaultDispatcher { contract_address: vault_addr }.cancel();
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('no pending request',))]
fn test_cancel_reverts_if_no_request() {
    let (token_addr, vault_addr) = setup();

    do_deposit(token_addr, vault_addr, DEPOSIT);

    // cancel without a pending request
    start_cheat_block_number_global(START_BLOCK);
    start_cheat_caller_address(vault_addr, recovery());
    IVaultDispatcher { contract_address: vault_addr }.cancel();
    stop_cheat_caller_address(vault_addr);
    stop_cheat_block_number_global();
}