use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
    spy_events, EventSpyAssertionsTrait,
};
use starknet::ContractAddress;
use token_trans::token::{TokenTransfer, ITokenTransferDispatcher, ITokenTransferDispatcherTrait};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn owner()     -> ContractAddress { 'owner'.try_into().unwrap() }
fn recipient() -> ContractAddress { 'recipient'.try_into().unwrap() }
fn other()     -> ContractAddress { 'other'.try_into().unwrap() }

fn deploy_token(initial_supply: u256, recipient: ContractAddress) -> ContractAddress {
    let class = declare("ERC20Mock").unwrap().contract_class();
    let name: ByteArray   = "Mock";
    let symbol: ByteArray = "MCK";
    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    initial_supply.serialize(ref calldata);
    recipient.serialize(ref calldata);
    let (addr, _) = class.deploy(@calldata).unwrap();
    addr
}

fn deploy_contract(token: ContractAddress) -> ContractAddress {
    let class = declare("TokenTransfer").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    recipient().serialize(ref calldata);
    token.serialize(ref calldata);

    // ✅ global cheat ensures constructor's get_caller_address() returns owner()
    start_cheat_caller_address_global(owner());
    let (addr, _) = class.deploy(@calldata).unwrap();
    stop_cheat_caller_address_global();
    addr
}

fn setup() -> (ContractAddress, ContractAddress) {
    let token_addr    = deploy_token(10_000_u256, owner());
    let contract_addr = deploy_contract(token_addr);
    (contract_addr, token_addr)
}

// helper: owner approves and deposits
fn do_deposit(contract_addr: ContractAddress, token_addr: ContractAddress, amount: u256) {
    let token = IERC20Dispatcher { contract_address: token_addr };

    // ✅ approve: owner approves contract to spend tokens
    start_cheat_caller_address(token_addr, owner());
    token.approve(contract_addr, amount);
    stop_cheat_caller_address(token_addr);

    // ✅ deposit: owner calls deposit on contract
    start_cheat_caller_address(contract_addr, owner());
    ITokenTransferDispatcher { contract_address: contract_addr }.deposit(amount);
    stop_cheat_caller_address(contract_addr);
}

// ---------------------------------------------------------------------------
// Constructor tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_owner_and_recipient() {
    let (contract_addr, token_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };

    assert(token.balance_of(owner())       == 10_000_u256, 'owner should have tokens');
    assert(token.balance_of(contract_addr) == 0_u256,      'contract should be empty');
}

// ---------------------------------------------------------------------------
// deposit() tests
// ---------------------------------------------------------------------------
#[test]
fn test_deposit_transfers_tokens_to_contract() {
    let (contract_addr, token_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };

    do_deposit(contract_addr, token_addr, 1000_u256);

    assert(token.balance_of(contract_addr) == 1000_u256, 'contract should have 1000');
    assert(token.balance_of(owner())       == 9000_u256, 'owner should have 9000');
}

#[test]
fn test_deposit_can_be_called_multiple_times() {
    let (contract_addr, token_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };

    do_deposit(contract_addr, token_addr, 500_u256);
    do_deposit(contract_addr, token_addr, 300_u256);

    assert(token.balance_of(contract_addr) == 800_u256, 'should accumulate deposits');
}

#[test]
#[should_panic(expected: ('only the owner',))]
fn test_deposit_reverts_if_not_owner() {
    let (contract_addr, _) = setup();

    start_cheat_caller_address(contract_addr, other());
    ITokenTransferDispatcher { contract_address: contract_addr }.deposit(100_u256);
    stop_cheat_caller_address(contract_addr);
}

#[test]
#[should_panic(expected: ('ERC20: insufficient allowance',))]
fn test_deposit_reverts_if_not_approved() {
    let (contract_addr, _) = setup();

    // owner calls deposit WITHOUT approving first
    // OZ ERC20 panics internally — 'deposit failed' is never reached
    start_cheat_caller_address(contract_addr, owner());
    ITokenTransferDispatcher { contract_address: contract_addr }.deposit(100_u256);
    stop_cheat_caller_address(contract_addr);
}

// ---------------------------------------------------------------------------
// withdraw() tests
// ---------------------------------------------------------------------------
#[test]
fn test_withdraw_exact_amount() {
    let (contract_addr, token_addr) = setup();
    let token    = IERC20Dispatcher { contract_address: token_addr };
    let contract = ITokenTransferDispatcher { contract_address: contract_addr };

    do_deposit(contract_addr, token_addr, 1000_u256);

    start_cheat_caller_address(contract_addr, recipient());
    contract.withdraw(400_u256);
    stop_cheat_caller_address(contract_addr);

    assert(token.balance_of(recipient())   == 400_u256, 'recipient should have 400');
    assert(token.balance_of(contract_addr) == 600_u256, 'contract should have 600');
}

#[test]
fn test_withdraw_capped_at_balance() {
    let (contract_addr, token_addr) = setup();
    let token    = IERC20Dispatcher { contract_address: token_addr };
    let contract = ITokenTransferDispatcher { contract_address: contract_addr };

    do_deposit(contract_addr, token_addr, 300_u256);

    // request more than balance — should receive full balance
    start_cheat_caller_address(contract_addr, recipient());
    contract.withdraw(1000_u256);
    stop_cheat_caller_address(contract_addr);

    assert(token.balance_of(recipient())   == 300_u256, 'should receive capped amount');
    assert(token.balance_of(contract_addr) == 0_u256,   'contract should be empty');
}

#[test]
fn test_withdraw_full_balance() {
    let (contract_addr, token_addr) = setup();
    let token    = IERC20Dispatcher { contract_address: token_addr };
    let contract = ITokenTransferDispatcher { contract_address: contract_addr };

    do_deposit(contract_addr, token_addr, 1000_u256);

    start_cheat_caller_address(contract_addr, recipient());
    contract.withdraw(1000_u256);
    stop_cheat_caller_address(contract_addr);

    assert(token.balance_of(recipient())   == 1000_u256, 'recipient should have 1000');
    assert(token.balance_of(contract_addr) == 0_u256,    'contract should be empty');
}

#[test]
fn test_withdraw_multiple_times() {
    let (contract_addr, token_addr) = setup();
    let token    = IERC20Dispatcher { contract_address: token_addr };
    let contract = ITokenTransferDispatcher { contract_address: contract_addr };

    do_deposit(contract_addr, token_addr, 1000_u256);

    start_cheat_caller_address(contract_addr, recipient());
    contract.withdraw(300_u256);
    contract.withdraw(300_u256);
    stop_cheat_caller_address(contract_addr);

    assert(token.balance_of(recipient())   == 600_u256, 'recipient should have 600');
    assert(token.balance_of(contract_addr) == 400_u256, 'contract should have 400');
}

#[test]
#[should_panic(expected: ('only the recipient can withdraw',))]
fn test_withdraw_reverts_if_not_recipient() {
    let (contract_addr, token_addr) = setup();

    do_deposit(contract_addr, token_addr, 1000_u256);

    start_cheat_caller_address(contract_addr, other());
    ITokenTransferDispatcher { contract_address: contract_addr }.withdraw(100_u256);
    stop_cheat_caller_address(contract_addr);
}

#[test]
#[should_panic(expected: ('only the recipient can withdraw',))]
fn test_withdraw_reverts_if_owner_tries_to_withdraw() {
    let (contract_addr, token_addr) = setup();

    do_deposit(contract_addr, token_addr, 1000_u256);

    // ✅ owner is NOT the recipient — should revert
    start_cheat_caller_address(contract_addr, owner());
    ITokenTransferDispatcher { contract_address: contract_addr }.withdraw(100_u256);
    stop_cheat_caller_address(contract_addr);
}

#[test]
#[should_panic(expected: ('the contract balance is zero',))]
fn test_withdraw_reverts_if_balance_zero() {
    let (contract_addr, _) = setup();

    start_cheat_caller_address(contract_addr, recipient());
    ITokenTransferDispatcher { contract_address: contract_addr }.withdraw(100_u256);
    stop_cheat_caller_address(contract_addr);
}

// ---------------------------------------------------------------------------
// Event tests
// ---------------------------------------------------------------------------
#[test]
fn test_withdraw_emits_event_with_actual_amount() {
    let (contract_addr, token_addr) = setup();
    let contract = ITokenTransferDispatcher { contract_address: contract_addr };

    do_deposit(contract_addr, token_addr, 1000_u256);

    let mut spy = spy_events();

    start_cheat_caller_address(contract_addr, recipient());
    contract.withdraw(400_u256);
    stop_cheat_caller_address(contract_addr);

    spy.assert_emitted(@array![
        (
            contract_addr,
            TokenTransfer::Event::Withdraw(
                TokenTransfer::Withdraw { sender: recipient(), amount: 400_u256 }
            )
        )
    ]);
}

#[test]
fn test_withdraw_event_shows_capped_amount() {
    let (contract_addr, token_addr) = setup();
    let contract = ITokenTransferDispatcher { contract_address: contract_addr };

    do_deposit(contract_addr, token_addr, 300_u256);

    let mut spy = spy_events();

    start_cheat_caller_address(contract_addr, recipient());
    contract.withdraw(1000_u256);  // request > balance
    stop_cheat_caller_address(contract_addr);

    // event should show actual transferred amount (300), not requested (1000)
    spy.assert_emitted(@array![
        (
            contract_addr,
            TokenTransfer::Event::Withdraw(
                TokenTransfer::Withdraw { sender: recipient(), amount: 300_u256 }
            )
        )
    ]);
}

// ---------------------------------------------------------------------------
// Full flow test
// ---------------------------------------------------------------------------
#[test]
fn test_full_flow() {
    let (contract_addr, token_addr) = setup();
    let token    = IERC20Dispatcher { contract_address: token_addr };
    let contract = ITokenTransferDispatcher { contract_address: contract_addr };

    // 1. owner deposits
    do_deposit(contract_addr, token_addr, 1000_u256);
    assert(token.balance_of(contract_addr) == 1000_u256, 'step1: wrong balance');

    // 2. recipient withdraws partial
    start_cheat_caller_address(contract_addr, recipient());
    contract.withdraw(600_u256);
    stop_cheat_caller_address(contract_addr);
    assert(token.balance_of(recipient())   == 600_u256, 'step2: wrong recipient bal');
    assert(token.balance_of(contract_addr) == 400_u256, 'step2: wrong contract bal');

    // 3. owner deposits more
    do_deposit(contract_addr, token_addr, 500_u256);
    assert(token.balance_of(contract_addr) == 900_u256, 'step3: wrong balance');

    // 4. recipient withdraws more than balance — capped
    start_cheat_caller_address(contract_addr, recipient());
    contract.withdraw(2000_u256);
    stop_cheat_caller_address(contract_addr);
    assert(token.balance_of(recipient())   == 1500_u256, 'step4: wrong recipient bal');
    assert(token.balance_of(contract_addr) == 0_u256,    'step4: should be empty');
}