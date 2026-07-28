use std::env;

use anyhow::{Context, Result};

pub fn string(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.into())
}

pub fn u32(name: &str, default: u32) -> Result<u32> {
    string(name, &default.to_string())
        .parse()
        .with_context(|| format!("invalid {name}"))
}

pub fn u64(name: &str, default: u64) -> Result<u64> {
    string(name, &default.to_string())
        .parse()
        .with_context(|| format!("invalid {name}"))
}

pub fn i64(name: &str, default: i64) -> Result<i64> {
    string(name, &default.to_string())
        .parse()
        .with_context(|| format!("invalid {name}"))
}
