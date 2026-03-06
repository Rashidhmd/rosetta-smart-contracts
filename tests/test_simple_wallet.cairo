use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use simple_wallet::simple_wallet::{ISimpleWalletDispatcher, ISimpleWalletDispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn owner() -> ContractAddress     { 'owner'.try_into().unwrap() }
fn recipient() -> ContractAddress { 'recipient'.try_into().unwrap() }
fn stranger() -> ContractAddress  { 'stranger'.try_into().unwrap() }

const DEPOSIT: u256  = 1000_u256;
const TX_VALUE: u256 = 200_u256;

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

fn deploy_wallet(token_addr: ContractAddress) -> ContractAddress {
    let class = declare("SimpleWallet").unwrap().contract_class();

    let calldata: Array<felt252> = array![
        owner().into(),
        token_addr.into(),
    ];

    start_cheat_caller_address_global(owner());
    let (wallet_addr, _) = class.deploy(@calldata).unwrap();
    stop_cheat_caller_address_global();

    wallet_addr
}

fn setup() -> (ContractAddress, ContractAddress) {
    let token_addr  = deploy_token();
    let wallet_addr = deploy_wallet(token_addr);
    (token_addr, wallet_addr)
}

// helper: approve + deposit
fn do_deposit(token_addr: ContractAddress, wallet_addr: ContractAddress, amount: u256) {
    let token = IERC20Dispatcher { contract_address: token_addr };

    start_cheat_caller_address(token_addr, owner());
    token.approve(wallet_addr, amount);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(wallet_addr, owner());
    ISimpleWalletDispatcher { contract_address: wallet_addr }.deposit(amount);
    stop_cheat_caller_address(wallet_addr);
}

// helper: create a transaction to recipient with TX_VALUE
fn do_create_tx(wallet_addr: ContractAddress) {
    start_cheat_caller_address(wallet_addr, owner());
    ISimpleWalletDispatcher { contract_address: wallet_addr }
        .create_transaction(recipient(), TX_VALUE, "tx_data");
    stop_cheat_caller_address(wallet_addr);
}

// ---------------------------------------------------------------------------
// Constructor tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_fields() {
    let (_, wallet_addr) = setup();
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    assert(wallet.get_owner()             == owner(), 'wrong owner');
    assert(wallet.get_balance()           == 0,       'balance should be 0');
    assert(wallet.get_transaction_count() == 0,       'tx count should be 0');
}

#[test]
fn test_constructor_reverts_if_zero_owner() {
    let token_addr = deploy_token();
    let class = declare("SimpleWallet").unwrap().contract_class();

    let calldata: Array<felt252> = array![
        starknet::contract_address_const::<0>().into(),
        token_addr.into(),
    ];

    let result = class.deploy(@calldata);
    assert(result.is_err(), 'should fail with zero address');
}

// ---------------------------------------------------------------------------
// deposit() tests
// ---------------------------------------------------------------------------
#[test]
fn test_deposit_increases_balance() {
    let (token_addr, wallet_addr) = setup();
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    do_deposit(token_addr, wallet_addr, DEPOSIT);

    assert(wallet.get_balance() == DEPOSIT, 'wrong balance after deposit');
}

#[test]
fn test_deposit_multiple_times_accumulates() {
    let (token_addr, wallet_addr) = setup();
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    do_deposit(token_addr, wallet_addr, 400_u256);
    do_deposit(token_addr, wallet_addr, 600_u256);

    assert(wallet.get_balance() == 1000_u256, 'wrong accumulated balance');
}

#[test]
#[should_panic(expected: ('only the owner',))]
fn test_deposit_reverts_if_not_owner() {
    let (token_addr, wallet_addr) = setup();

    start_cheat_caller_address(wallet_addr, stranger());
    ISimpleWalletDispatcher { contract_address: wallet_addr }.deposit(DEPOSIT);
    stop_cheat_caller_address(wallet_addr);
}

// ---------------------------------------------------------------------------
// create_transaction() tests
// ---------------------------------------------------------------------------
#[test]
fn test_create_transaction_stores_correctly() {
    let (token_addr, wallet_addr) = setup();
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    do_deposit(token_addr, wallet_addr, DEPOSIT);
    do_create_tx(wallet_addr);

    assert(wallet.get_transaction_count() == 1, 'tx count should be 1');

    let tx = wallet.get_transaction(0);
    assert(tx.to       == recipient(), 'wrong to');
    assert(tx.value    == TX_VALUE,    'wrong value');
    assert(tx.executed == false,       'should not be executed');
}

#[test]
fn test_create_multiple_transactions() {
    let (token_addr, wallet_addr) = setup();
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    do_deposit(token_addr, wallet_addr, DEPOSIT);
    do_create_tx(wallet_addr);
    do_create_tx(wallet_addr);
    do_create_tx(wallet_addr);

    assert(wallet.get_transaction_count() == 3, 'tx count should be 3');

    // each tx stored independently
    assert(wallet.get_transaction(0).value == TX_VALUE, 'tx0 wrong value');
    assert(wallet.get_transaction(1).value == TX_VALUE, 'tx1 wrong value');
    assert(wallet.get_transaction(2).value == TX_VALUE, 'tx2 wrong value');
}

#[test]
#[should_panic(expected: ('only the owner',))]
fn test_create_transaction_reverts_if_not_owner() {
    let (_, wallet_addr) = setup();

    start_cheat_caller_address(wallet_addr, stranger());
    ISimpleWalletDispatcher { contract_address: wallet_addr }
        .create_transaction(recipient(), TX_VALUE, "data");
    stop_cheat_caller_address(wallet_addr);
}

// ---------------------------------------------------------------------------
// execute_transaction() tests
// ---------------------------------------------------------------------------
#[test]
fn test_execute_transaction_transfers_tokens() {
    let (token_addr, wallet_addr) = setup();
    let token  = IERC20Dispatcher { contract_address: token_addr };
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    do_deposit(token_addr, wallet_addr, DEPOSIT);
    do_create_tx(wallet_addr);

    let recipient_before = token.balance_of(recipient());

    start_cheat_caller_address(wallet_addr, owner());
    wallet.execute_transaction(0);
    stop_cheat_caller_address(wallet_addr);

    assert(wallet.get_balance()              == DEPOSIT - TX_VALUE,          'wrong wallet balance');
    assert(token.balance_of(recipient())     == recipient_before + TX_VALUE,  'recipient not paid');
    assert(wallet.get_transaction(0).executed == true,                        'tx should be executed');
}

#[test]
fn test_execute_multiple_transactions_independently() {
    let (token_addr, wallet_addr) = setup();
    let token  = IERC20Dispatcher { contract_address: token_addr };
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    do_deposit(token_addr, wallet_addr, DEPOSIT);
    do_create_tx(wallet_addr); // tx 0
    do_create_tx(wallet_addr); // tx 1

    start_cheat_caller_address(wallet_addr, owner());
    wallet.execute_transaction(0);
    stop_cheat_caller_address(wallet_addr);

    // tx 1 still not executed
    assert(wallet.get_transaction(0).executed == true,  'tx0 should be executed');
    assert(wallet.get_transaction(1).executed == false, 'tx1 should not be executed');
    assert(wallet.get_balance() == DEPOSIT - TX_VALUE,  'wrong balance after tx0');

    start_cheat_caller_address(wallet_addr, owner());
    wallet.execute_transaction(1);
    stop_cheat_caller_address(wallet_addr);

    assert(wallet.get_transaction(1).executed == true,        'tx1 should be executed');
    assert(wallet.get_balance() == DEPOSIT - TX_VALUE * 2,    'wrong balance after tx1');
    assert(token.balance_of(recipient()) == TX_VALUE * 2,     'recipient should have 2x');
}

#[test]
#[should_panic(expected: ('only the owner',))]
fn test_execute_transaction_reverts_if_not_owner() {
    let (token_addr, wallet_addr) = setup();

    do_deposit(token_addr, wallet_addr, DEPOSIT);
    do_create_tx(wallet_addr);

    start_cheat_caller_address(wallet_addr, stranger());
    ISimpleWalletDispatcher { contract_address: wallet_addr }.execute_transaction(0);
    stop_cheat_caller_address(wallet_addr);
}

#[test]
#[should_panic(expected: ('transaction does not exist',))]
fn test_execute_transaction_reverts_if_not_found() {
    let (_, wallet_addr) = setup();

    start_cheat_caller_address(wallet_addr, owner());
    ISimpleWalletDispatcher { contract_address: wallet_addr }.execute_transaction(99);
    stop_cheat_caller_address(wallet_addr);
}

#[test]
#[should_panic(expected: ('transaction already executed',))]
fn test_execute_transaction_reverts_if_already_executed() {
    let (token_addr, wallet_addr) = setup();

    do_deposit(token_addr, wallet_addr, DEPOSIT);
    do_create_tx(wallet_addr);

    start_cheat_caller_address(wallet_addr, owner());
    ISimpleWalletDispatcher { contract_address: wallet_addr }.execute_transaction(0);
    // execute again — should panic
    ISimpleWalletDispatcher { contract_address: wallet_addr }.execute_transaction(0);
    stop_cheat_caller_address(wallet_addr);
}

#[test]
#[should_panic(expected: ('insufficient funds',))]
fn test_execute_transaction_reverts_if_insufficient_funds() {
    let (token_addr, wallet_addr) = setup();

    // deposit less than tx value
    do_deposit(token_addr, wallet_addr, TX_VALUE - 1);
    do_create_tx(wallet_addr);

    start_cheat_caller_address(wallet_addr, owner());
    ISimpleWalletDispatcher { contract_address: wallet_addr }.execute_transaction(0);
    stop_cheat_caller_address(wallet_addr);
}

// ---------------------------------------------------------------------------
// withdraw() tests
// ---------------------------------------------------------------------------
#[test]
fn test_withdraw_sends_full_balance_to_owner() {
    let (token_addr, wallet_addr) = setup();
    let token  = IERC20Dispatcher { contract_address: token_addr };
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    do_deposit(token_addr, wallet_addr, DEPOSIT);
    let owner_before = token.balance_of(owner());

    start_cheat_caller_address(wallet_addr, owner());
    wallet.withdraw();
    stop_cheat_caller_address(wallet_addr);

    assert(wallet.get_balance()      == 0,                     'wallet should be empty');
    assert(token.balance_of(owner()) == owner_before + DEPOSIT, 'owner should get all');
}

#[test]
fn test_withdraw_after_partial_execution() {
    let (token_addr, wallet_addr) = setup();
    let token  = IERC20Dispatcher { contract_address: token_addr };
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    do_deposit(token_addr, wallet_addr, DEPOSIT);
    do_create_tx(wallet_addr);

    // execute one tx then withdraw the rest
    start_cheat_caller_address(wallet_addr, owner());
    wallet.execute_transaction(0);
    stop_cheat_caller_address(wallet_addr);

    let owner_before = token.balance_of(owner());
    let remaining    = DEPOSIT - TX_VALUE;

    start_cheat_caller_address(wallet_addr, owner());
    wallet.withdraw();
    stop_cheat_caller_address(wallet_addr);

    assert(wallet.get_balance()      == 0,                      'wallet should be empty');
    assert(token.balance_of(owner()) == owner_before + remaining,'owner gets remainder');
}

#[test]
#[should_panic(expected: ('only the owner',))]
fn test_withdraw_reverts_if_not_owner() {
    let (token_addr, wallet_addr) = setup();

    do_deposit(token_addr, wallet_addr, DEPOSIT);

    start_cheat_caller_address(wallet_addr, stranger());
    ISimpleWalletDispatcher { contract_address: wallet_addr }.withdraw();
    stop_cheat_caller_address(wallet_addr);
}

// ---------------------------------------------------------------------------
// get_transaction() tests
// ---------------------------------------------------------------------------
#[test]
#[should_panic(expected: ('transaction does not exist',))]
fn test_get_transaction_reverts_if_not_found() {
    let (_, wallet_addr) = setup();
    let wallet = ISimpleWalletDispatcher { contract_address: wallet_addr };

    wallet.get_transaction(0); // nothing created yet
}