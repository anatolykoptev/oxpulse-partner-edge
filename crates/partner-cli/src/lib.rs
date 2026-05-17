//! Re-exports for integration testing of partner-cli commands.
//!
//! The binary entry point (`main.rs`) handles CLI parsing and DB connection;
//! the `commands` module contains the pure async logic. Exposing it as a
//! library target lets the server's integration-test suite call the command
//! functions directly against a test database without spawning a subprocess.

pub mod commands;
