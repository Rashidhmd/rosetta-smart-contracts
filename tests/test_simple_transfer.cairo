use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global, // ✅ add these
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use simple_transfer::simple_transfer::{ISimpleTransferDispatcher, ISimpleTransferDispatcherTrait};

fn owner() -> ContractAddress {
    'owner'.try_into().unwrap()
}

fn recipient() -> ContractAddress {
    'recipient'.try_into().unwrap()
}

fn stranger() -> ContractAddress {
    'stranger'.try_into().unwrap()
}

fn deploy_token(initial_supply: u256) -> ContractAddress {
    let class = declare("ERC20Mock").unwrap().contract_class();

    let name: ByteArray = "MockToken";
    let symbol: ByteArray = "MTK";

    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    initial_supply.serialize(ref calldata);
    calldata.append(owner().into());

    let (token_addr, _) = class.deploy(@calldata).unwrap();
    token_addr
}

fn deploy_simple_transfer(token: ContractAddress) -> ContractAddress {
    let class = declare("SimpleTransfer").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![
        recipient().into(),
        token.into(),
    ];

    // cheat globally so the constructor sees owner() as msg.sender
    start_cheat_caller_address_global(owner());
    let (st_addr, _) = class.deploy(@calldata).unwrap();
    stop_cheat_caller_address_global();

    st_addr
}

fn setup() -> (ContractAddress, ContractAddress) {
    let token_addr = deploy_token(1000);
    let st_addr = deploy_simple_transfer(token_addr);
    (token_addr, st_addr)
}

// helper to avoid repeating approve + deposit in every test
fn deposit(token_addr: ContractAddress, st_addr: ContractAddress, amount: u256) {
    let token = IERC20Dispatcher { contract_address: token_addr };
    let st    = ISimpleTransferDispatcher { contract_address: st_addr };

    start_cheat_caller_address(token_addr, owner());
    token.approve(st_addr, amount);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(st_addr, owner());
    st.deposit(amount);
    stop_cheat_caller_address(st_addr);
}

#[test]
fn test_constructor_sets_fields() {
    let (token_addr, st_addr) = setup();
    let st = ISimpleTransferDispatcher { contract_address: st_addr };

    assert(st.get_owner()     == owner(),     'wrong owner');
    assert(st.get_recipient() == recipient(), 'wrong recipient');
    assert(st.get_token()     == token_addr,  'wrong token');
}

#[test]
fn test_deposit_increases_balance() {
    let (token_addr, st_addr) = setup();
    let st = ISimpleTransferDispatcher { contract_address: st_addr };

    deposit(token_addr, st_addr, 500);

    assert(st.get_balance() == 500, 'balance should be 500');
}

#[test]
fn test_withdraw_moves_tokens_to_recipient() {
    let (token_addr, st_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };
    let st    = ISimpleTransferDispatcher { contract_address: st_addr };

    deposit(token_addr, st_addr, 500);

    start_cheat_caller_address(st_addr, recipient());
    st.withdraw(200);
    stop_cheat_caller_address(st_addr);

    assert(st.get_balance()              == 300, 'contract should have 300');
    assert(token.balance_of(recipient()) == 200, 'recipient should have 200');
}

#[test]
fn test_withdraw_full_balance() {
    let (token_addr, st_addr) = setup();
    let token = IERC20Dispatcher { contract_address: token_addr };
    let st    = ISimpleTransferDispatcher { contract_address: st_addr };

    deposit(token_addr, st_addr, 1000);

    start_cheat_caller_address(st_addr, recipient());
    st.withdraw(1000);
    stop_cheat_caller_address(st_addr);

    assert(st.get_balance()              == 0,    'contract should be empty');
    assert(token.balance_of(recipient()) == 1000, 'recipient should have 1000');
}

#[test]
#[should_panic(expected: ('only the owner can deposit',))]
fn test_deposit_reverts_if_not_owner() {
    let (token_addr, st_addr) = setup();
    let st = ISimpleTransferDispatcher { contract_address: st_addr };

    start_cheat_caller_address(st_addr, stranger());
    st.deposit(100);
    stop_cheat_caller_address(st_addr);
}

#[test]
#[should_panic(expected: ('only the recipient can withdraw',))]
fn test_withdraw_reverts_if_not_recipient() {
    let (token_addr, st_addr) = setup();
    let st = ISimpleTransferDispatcher { contract_address: st_addr };

    deposit(token_addr, st_addr, 500);

    start_cheat_caller_address(st_addr, stranger());
    st.withdraw(100);
    stop_cheat_caller_address(st_addr);
}

#[test]
#[should_panic(expected: ('balance less than amount',))]
fn test_withdraw_reverts_if_insufficient_balance() {
    let (token_addr, st_addr) = setup();
    let st = ISimpleTransferDispatcher { contract_address: st_addr };

    deposit(token_addr, st_addr, 100);

    start_cheat_caller_address(st_addr, recipient());
    st.withdraw(999);
    stop_cheat_caller_address(st_addr);
}