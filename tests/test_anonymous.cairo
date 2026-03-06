use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use anonymous::anonymous::{IAnonymousDataDispatcher, IAnonymousDataDispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn user1() -> ContractAddress { 'user1'.try_into().unwrap() }
fn user2() -> ContractAddress { 'user2'.try_into().unwrap() }

fn deploy() -> ContractAddress {
    let class = declare("AnonymousData").unwrap().contract_class();
    let (addr, _) = class.deploy(@array![]).unwrap();
    addr
}

fn setup() -> ContractAddress {
    deploy()
}

// ---------------------------------------------------------------------------
// get_id() tests
// ---------------------------------------------------------------------------
#[test]
fn test_get_id_returns_deterministic_hash() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    start_cheat_caller_address(contract_addr, user1());
    let id1 = contract.get_id(42_u256);
    let id2 = contract.get_id(42_u256);
    stop_cheat_caller_address(contract_addr);

    // same caller + same nonce → same id
    assert(id1 == id2, 'same inputs should give same id');
}

#[test]
fn test_get_id_different_nonce_gives_different_id() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    start_cheat_caller_address(contract_addr, user1());
    let id1 = contract.get_id(1_u256);
    let id2 = contract.get_id(2_u256);
    stop_cheat_caller_address(contract_addr);

    // same caller + different nonce → different id
    assert(id1 != id2, 'different nonce should differ');
}

#[test]
fn test_get_id_different_caller_gives_different_id() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    start_cheat_caller_address(contract_addr, user1());
    let id1 = contract.get_id(42_u256);
    stop_cheat_caller_address(contract_addr);

    start_cheat_caller_address(contract_addr, user2());
    let id2 = contract.get_id(42_u256);
    stop_cheat_caller_address(contract_addr);

    // different caller + same nonce → different id
    assert(id1 != id2, 'different caller should differ');
}

// ---------------------------------------------------------------------------
// store_data() tests
// ---------------------------------------------------------------------------
#[test]
fn test_store_data_stores_correctly() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    start_cheat_caller_address(contract_addr, user1());
    let id = contract.get_id(1_u256);
    contract.store_data("hello world", id);
    let data = contract.get_my_data(1_u256);
    stop_cheat_caller_address(contract_addr);

    assert(data == "hello world", 'data should match');
}

#[test]
fn test_store_data_with_long_data() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    let long_data: ByteArray = "this is a long arbitrary data string that exceeds 31 bytes easily";

    start_cheat_caller_address(contract_addr, user1());
    let id = contract.get_id(99_u256);
    contract.store_data(long_data.clone(), id);
    let data = contract.get_my_data(99_u256);
    stop_cheat_caller_address(contract_addr);

    assert(data == long_data, 'long data should match');
}

#[test]
#[should_panic(expected: ('data already stored for id',))]
fn test_store_data_reverts_if_already_stored() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    start_cheat_caller_address(contract_addr, user1());
    let id = contract.get_id(1_u256);
    contract.store_data("first", id);
    contract.store_data("second", id); // should panic
    stop_cheat_caller_address(contract_addr);
}

#[test]
fn test_store_data_different_nonces_are_independent() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    start_cheat_caller_address(contract_addr, user1());

    // user can store multiple entries with different nonces
    let id1 = contract.get_id(1_u256);
    let id2 = contract.get_id(2_u256);
    let id3 = contract.get_id(3_u256);

    contract.store_data("data for nonce 1", id1);
    contract.store_data("data for nonce 2", id2);
    contract.store_data("data for nonce 3", id3);

    assert(contract.get_my_data(1_u256) == "data for nonce 1", 'wrong data nonce 1');
    assert(contract.get_my_data(2_u256) == "data for nonce 2", 'wrong data nonce 2');
    assert(contract.get_my_data(3_u256) == "data for nonce 3", 'wrong data nonce 3');

    stop_cheat_caller_address(contract_addr);
}

// ---------------------------------------------------------------------------
// get_my_data() tests
// ---------------------------------------------------------------------------
#[test]
fn test_get_my_data_returns_empty_if_not_stored() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    start_cheat_caller_address(contract_addr, user1());
    let data = contract.get_my_data(999_u256);
    stop_cheat_caller_address(contract_addr);

    assert(data == "", 'should return empty');
}

#[test]
fn test_get_my_data_user2_cannot_access_user1_data() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    // user1 stores data with nonce 1
    start_cheat_caller_address(contract_addr, user1());
    let id = contract.get_id(1_u256);
    contract.store_data("secret data", id);
    stop_cheat_caller_address(contract_addr);

    // user2 uses same nonce but gets different id → empty data
    start_cheat_caller_address(contract_addr, user2());
    let data = contract.get_my_data(1_u256);
    stop_cheat_caller_address(contract_addr);

    assert(data == "", 'user2 should not see user1 data');
}

// ---------------------------------------------------------------------------
// Full flow test
// ---------------------------------------------------------------------------
#[test]
fn test_full_flow() {
    let contract_addr = setup();
    let contract = IAnonymousDataDispatcher { contract_address: contract_addr };

    // 1. user1 gets their id for nonce 42
    start_cheat_caller_address(contract_addr, user1());
    let id = contract.get_id(42_u256);
    assert(id != 0, 'id should not be zero');

    // 2. user1 stores data under that id
    contract.store_data("my anonymous data", id);

    // 3. user1 retrieves data using same nonce
    let retrieved = contract.get_my_data(42_u256);
    assert(retrieved == "my anonymous data", 'data should match');

    // 4. user1 uses new nonce for new entry
    let id2 = contract.get_id(43_u256);
    assert(id2 != id, 'new nonce should give new id');
    contract.store_data("more data", id2);
    assert(contract.get_my_data(43_u256) == "more data", 'second entry should work');

    stop_cheat_caller_address(contract_addr);

    // 5. user2 with same nonce cannot see user1 data
    start_cheat_caller_address(contract_addr, user2());
    assert(contract.get_my_data(42_u256) == "", 'user2 should see nothing');
    stop_cheat_caller_address(contract_addr);
}