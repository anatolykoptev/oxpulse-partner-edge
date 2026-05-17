//! Phase 4.3c — body builder unit tests.
use opec::secrets::register;
use std::fs;
use tempfile::TempDir;

#[test]
fn body_required_fields_only() {
    let tmp = TempDir::new().unwrap();
    fs::write(tmp.path().join("reality.pub"), "REALITY_PUB_44_CHARS=\n").unwrap();
    fs::write(tmp.path().join("reality.uuid"), "11111111-2222-3333-4444-555555555555\n").unwrap();
    fs::write(tmp.path().join("awg.pub"), "AWG_PUB_KEY_BASE64\n").unwrap();

    let body = register::build_body(&register::BodyInputs {
        partner_id: "zvonilka",
        domain: "zvonilka.net",
        token: "test-token",
        public_ip: "1.2.3.4",
        region: None,
        reality_pub_file: tmp.path().join("reality.pub"),
        reality_uuid_file: tmp.path().join("reality.uuid"),
        awg_pub_file: tmp.path().join("awg.pub"),
        branding_config: None,
    })
    .expect("body builds");

    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["partner_id"], "zvonilka");
    assert_eq!(v["domain"], "zvonilka.net");
    assert_eq!(v["token"], "test-token");
    assert_eq!(v["public_ip"], "1.2.3.4");
    assert_eq!(v["reality_public_key"], "REALITY_PUB_44_CHARS=");
    assert_eq!(v["reality_uuid"], "11111111-2222-3333-4444-555555555555");
    assert_eq!(v["awg_pubkey"], "AWG_PUB_KEY_BASE64");
    assert!(v.get("region").is_none(), "region absent when not provided");
    assert!(v.get("branding").is_none(), "branding absent when not provided");
}

#[test]
fn body_with_region() {
    let tmp = TempDir::new().unwrap();
    fs::write(tmp.path().join("a.pub"), "X\n").unwrap();
    fs::write(tmp.path().join("a.uuid"), "11111111-2222-3333-4444-555555555555\n").unwrap();
    fs::write(tmp.path().join("b.pub"), "Y\n").unwrap();

    let body = register::build_body(&register::BodyInputs {
        partner_id: "p",
        domain: "d.net",
        token: "t",
        public_ip: "1.1.1.1",
        region: Some("ru-msk".to_string()),
        reality_pub_file: tmp.path().join("a.pub"),
        reality_uuid_file: tmp.path().join("a.uuid"),
        awg_pub_file: tmp.path().join("b.pub"),
        branding_config: None,
    })
    .unwrap();
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["region"], "ru-msk");
}

#[test]
fn body_with_branding_config_file() {
    let tmp = TempDir::new().unwrap();
    fs::write(tmp.path().join("a.pub"), "X\n").unwrap();
    fs::write(tmp.path().join("a.uuid"), "11111111-2222-3333-4444-555555555555\n").unwrap();
    fs::write(tmp.path().join("b.pub"), "Y\n").unwrap();
    let branding = r#"{"display_name":"Test","logo":{"light":"/l.svg","dark":"/d.svg"}}"#;
    fs::write(tmp.path().join("brand.json"), branding).unwrap();

    let body = register::build_body(&register::BodyInputs {
        partner_id: "p",
        domain: "d.net",
        token: "t",
        public_ip: "1.1.1.1",
        region: None,
        reality_pub_file: tmp.path().join("a.pub"),
        reality_uuid_file: tmp.path().join("a.uuid"),
        awg_pub_file: tmp.path().join("b.pub"),
        branding_config: Some(tmp.path().join("brand.json")),
    })
    .unwrap();
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["branding"]["display_name"], "Test");
    assert_eq!(v["branding"]["logo"]["light"], "/l.svg");
}

#[test]
fn body_invalid_branding_json_errors() {
    let tmp = TempDir::new().unwrap();
    fs::write(tmp.path().join("a.pub"), "X\n").unwrap();
    fs::write(tmp.path().join("a.uuid"), "11111111-2222-3333-4444-555555555555\n").unwrap();
    fs::write(tmp.path().join("b.pub"), "Y\n").unwrap();
    fs::write(tmp.path().join("brand.json"), "not-json").unwrap();

    let result = register::build_body(&register::BodyInputs {
        partner_id: "p",
        domain: "d.net",
        token: "t",
        public_ip: "1.1.1.1",
        region: None,
        reality_pub_file: tmp.path().join("a.pub"),
        reality_uuid_file: tmp.path().join("a.uuid"),
        awg_pub_file: tmp.path().join("b.pub"),
        branding_config: Some(tmp.path().join("brand.json")),
    });
    assert!(result.is_err());
}
