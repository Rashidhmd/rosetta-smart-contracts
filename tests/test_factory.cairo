use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
    start_cheat_account_contract_address, stop_cheat_account_contract_address,
    start_cheat_account_contract_address_global, stop_cheat_account_contract_address_global,
};
use starknet::ContractAddress;
use factory::factory::{
    IFactoryDispatcher, IFactoryDispatcherTrait,
    IProductDispatcher, IProductDispatcherTrait,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn owner() -> ContractAddress    { 'owner'.try_into().unwrap() }
fn stranger() -> ContractAddress { 'stranger'.try_into().unwrap() }

fn deploy_factory() -> ContractAddress {
    let product_class = declare("Product").unwrap().contract_class();
    let factory_class = declare("Factory").unwrap().contract_class();

    // pass Product class hash to Factory constructor
    let calldata: Array<felt252> = array![(*product_class.class_hash).into()];
    let (factory_addr, _) = factory_class.deploy(@calldata).unwrap();
    factory_addr
}

fn setup() -> ContractAddress {
    deploy_factory()
}

// helper: create a product as owner
fn do_create(factory_addr: ContractAddress, tag: ByteArray) -> ContractAddress {
    // cheat both caller and tx.origin — Product stores tx.origin as owner
    start_cheat_account_contract_address_global(owner());
    start_cheat_caller_address(factory_addr, owner());

    let product_addr = IFactoryDispatcher { contract_address: factory_addr }
        .create_product(tag);

    stop_cheat_caller_address(factory_addr);
    stop_cheat_account_contract_address_global();

    product_addr
}

// ---------------------------------------------------------------------------
// Factory tests
// ---------------------------------------------------------------------------
#[test]
fn test_create_product_returns_address() {
    let factory_addr = setup();

    let product_addr = do_create(factory_addr, "my_product");

    // address should be non-zero
    assert(
        product_addr != starknet::contract_address_const::<0>(),
        'product address should not be 0'
    );
}

#[test]
fn test_get_products_returns_created_products() {
    let factory_addr = setup();
    let factory = IFactoryDispatcher { contract_address: factory_addr };

    let p1 = do_create(factory_addr, "product_one");
    let p2 = do_create(factory_addr, "product_two");
    let p3 = do_create(factory_addr, "product_three");

    start_cheat_caller_address(factory_addr, owner());
    let products = factory.get_products();
    stop_cheat_caller_address(factory_addr);

    assert(products.len() == 3, 'should have 3 products');
    assert(*products.at(0) == p1, 'wrong product at 0');
    assert(*products.at(1) == p2, 'wrong product at 1');
    assert(*products.at(2) == p3, 'wrong product at 2');
}

#[test]
fn test_get_products_is_per_user() {
    let factory_addr = setup();
    let factory = IFactoryDispatcher { contract_address: factory_addr };

    do_create(factory_addr, "owner_product_1");
    do_create(factory_addr, "owner_product_2");

    // global cheat for stranger too
    start_cheat_account_contract_address_global(stranger());
    start_cheat_caller_address(factory_addr, stranger());
    factory.create_product("stranger_product");
    stop_cheat_caller_address(factory_addr);
    stop_cheat_account_contract_address_global();

    start_cheat_caller_address(factory_addr, owner());
    let owner_products = factory.get_products();
    stop_cheat_caller_address(factory_addr);

    start_cheat_caller_address(factory_addr, stranger());
    let stranger_products = factory.get_products();
    stop_cheat_caller_address(factory_addr);

    assert(owner_products.len()    == 2, 'owner should have 2 products');
    assert(stranger_products.len() == 1, 'stranger should have 1 product');
}

#[test]
fn test_get_products_empty_for_new_user() {
    let factory_addr = setup();
    let factory = IFactoryDispatcher { contract_address: factory_addr };

    start_cheat_caller_address(factory_addr, stranger());
    let products = factory.get_products();
    stop_cheat_caller_address(factory_addr);

    assert(products.len() == 0, 'should be empty');
}

#[test]
fn test_each_product_has_unique_address() {
    let factory_addr = setup();

    let p1 = do_create(factory_addr, "same_tag");
    let p2 = do_create(factory_addr, "same_tag");
    let p3 = do_create(factory_addr, "same_tag");

    assert(p1 != p2, 'p1 and p2 should differ');
    assert(p2 != p3, 'p2 and p3 should differ');
    assert(p1 != p3, 'p1 and p3 should differ');
}

// ---------------------------------------------------------------------------
// Product tests
// ---------------------------------------------------------------------------
#[test]
fn test_product_get_tag_by_owner() {
    let factory_addr = setup();
    let product_addr = do_create(factory_addr, "hello_world");
    let product = IProductDispatcher { contract_address: product_addr };

    // owner can read tag
    start_cheat_caller_address(product_addr, owner());
    let tag = product.get_tag();
    stop_cheat_caller_address(product_addr);

    assert(tag == "hello_world", 'wrong tag');
}

#[test]
#[should_panic(expected: ('only the owner',))]
fn test_product_get_tag_reverts_if_not_owner() {
    let factory_addr = setup();
    let product_addr = do_create(factory_addr, "secret_tag");

    // stranger cannot read tag
    start_cheat_caller_address(product_addr, stranger());
    IProductDispatcher { contract_address: product_addr }.get_tag();
    stop_cheat_caller_address(product_addr);
}

#[test]
fn test_product_get_factory_returns_factory_address() {
    let factory_addr = setup();
    let product_addr = do_create(factory_addr, "tag");
    let product = IProductDispatcher { contract_address: product_addr };

    // anyone can call get_factory
    let returned_factory = product.get_factory();
    assert(returned_factory == factory_addr, 'wrong factory address');
}

#[test]
fn test_product_owner_is_tx_origin_not_factory() {
    let factory_addr = setup();
    let product_addr = do_create(factory_addr, "tag");
    let product = IProductDispatcher { contract_address: product_addr };

    // owner is the human (tx.origin), not the Factory contract
    assert(product.get_owner()   == owner(),       'owner should be tx origin');
    assert(product.get_factory() == factory_addr,  'factory should be factory');
    assert(product.get_owner()   != factory_addr,  'owner should not be factory');
}

#[test]
fn test_multiple_products_have_correct_factory() {
    let factory_addr = setup();

    let p1 = do_create(factory_addr, "tag1");
    let p2 = do_create(factory_addr, "tag2");

    assert(
        IProductDispatcher { contract_address: p1 }.get_factory() == factory_addr,
        'p1 wrong factory'
    );
    assert(
        IProductDispatcher { contract_address: p2 }.get_factory() == factory_addr,
        'p2 wrong factory'
    );
}
