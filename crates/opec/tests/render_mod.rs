//! Phase 2 Task 1 — shared template substitution helper tests.
//! Mirrors bats/test_render_template_golden.sh contracts.

use opec::render::substitute_from_env;
use serial_test::serial;
use std::env;

fn unset_test_vars() {
    for k in [
        "PARTNER_ID",
        "PARTNER_DOMAIN",
        "BACKEND_HOST",
        "BACKEND_PORT",
        "SFU_SIGNING_PUBLIC_KEY",
        "NONEXISTENT_VAR",
    ] {
        env::remove_var(k);
    }
}

#[test]
#[serial]
fn substitutes_single_line_vars() {
    unset_test_vars();
    env::set_var("PARTNER_ID", "zvonilka");
    env::set_var("PARTNER_DOMAIN", "zvonilka.net");
    env::set_var("BACKEND_HOST", "203.0.113.10");
    env::set_var("BACKEND_PORT", "5349");
    env::set_var("SFU_SIGNING_PUBLIC_KEY", "some-key");
    let tpl = "p={{PARTNER_ID}} d={{PARTNER_DOMAIN}} b={{BACKEND_HOST}}:{{BACKEND_PORT}} k={{SFU_SIGNING_PUBLIC_KEY}} e={{NONEXISTENT_VAR}}";
    let out = substitute_from_env(tpl);
    assert_eq!(
        out,
        "p=zvonilka d=zvonilka.net b=203.0.113.10:5349 k=some-key e="
    );
}

#[test]
#[serial]
fn unset_vars_become_empty() {
    unset_test_vars();
    let tpl = "p={{PARTNER_ID}}";
    let out = substitute_from_env(tpl);
    assert_eq!(out, "p=");
}

#[test]
#[serial]
fn preserves_dollar_and_percent_literals() {
    unset_test_vars();
    let tpl = "100% $HOME literal";
    let out = substitute_from_env(tpl);
    assert_eq!(out, "100% $HOME literal");
}

#[test]
#[serial]
fn preserves_multi_line_pem() {
    unset_test_vars();
    let pem = "-----BEGIN PUBLIC KEY-----\nLINE1\nLINE2\n-----END PUBLIC KEY-----";
    env::set_var("SFU_SIGNING_PUBLIC_KEY", pem);
    let tpl = "k={{SFU_SIGNING_PUBLIC_KEY}}\nrest";
    let out = substitute_from_env(tpl);
    assert_eq!(out, format!("k={}\nrest", pem));
}

#[test]
#[serial]
fn lowercase_placeholders_left_intact() {
    // Placeholder regex matches only [A-Z][A-Z0-9_]* — mirror bash render_template
    // (line in channel-render-lib.sh:42).
    unset_test_vars();
    let tpl = "{{lower}} {{MixedCase}} {{Mixed_Case}} {{UPPER}}";
    env::set_var("UPPER", "ok");
    let out = substitute_from_env(tpl);
    assert_eq!(out, "{{lower}} {{MixedCase}} {{Mixed_Case}} ok");
}
