//! bitacc: drive the bit-string accelerator FPGA build over its UART.
//!
//!   bitacc --port /dev/ttyUSB1 ping
//!   bitacc --port /dev/ttyUSB1 write <index> <value>
//!   bitacc --port /dev/ttyUSB1 read <index>
//!   bitacc --port /dev/ttyUSB1 exec <get|test|set|clear|toggle|0..7> <base> <offset>
//!   bitacc --port /dev/ttyUSB1 selftest [operations] [seed]
//!
//! Options: --baud N (default 115200), --words N (RAM size: 256 for the FPGA
//! build, 4 for the Tiny Tapeout chip).
//! Numbers are decimal or 0x-prefixed hex. The port is configured with `stty`
//! (115200 8N1 raw, 1 s read timeout); Linux and macOS.

mod protocol;

use protocol::*;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::process::{Command, ExitCode};

struct Port {
    file: File,
}

impl Port {
    fn open(path: &str, baud: u32) -> Result<Port, String> {
        let flag = if cfg!(target_os = "macos") {
            "-f"
        } else {
            "-F"
        };
        let status = Command::new("stty")
            .args([
                flag,
                path,
                &baud.to_string(),
                "raw",
                "-echo",
                "cs8",
                "-cstopb",
                "-parenb",
            ])
            .args(["-crtscts", "min", "0", "time", "10"])
            .status()
            .map_err(|e| format!("running stty: {e}"))?;
        if !status.success() {
            return Err(format!("stty could not configure {path}"));
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map_err(|e| format!("opening {path}: {e}"))?;
        let mut port = Port { file };
        port.drain();
        Ok(port)
    }

    /// Discard bytes left over from a previous session.
    fn drain(&mut self) {
        let mut buf = [0u8; 256];
        while matches!(self.file.read(&mut buf), Ok(n) if n > 0) {}
    }

    fn send(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.file
            .write_all(bytes)
            .map_err(|e| format!("write: {e}"))
    }

    fn recv(&mut self, n: usize) -> Result<Vec<u8>, String> {
        let mut out = vec![0u8; n];
        let mut got = 0;
        while got < n {
            match self.file.read(&mut out[got..]) {
                Ok(0) => return Err(format!("timeout: got {got} of {n} reply bytes")),
                Ok(k) => got += k,
                Err(e) => return Err(format!("read: {e}")),
            }
        }
        Ok(out)
    }

    fn ping(&mut self) -> Result<(), String> {
        self.send(&[PING])?;
        match self.recv(1)?[0] {
            PONG => Ok(()),
            b => Err(unexpected("ping", b)),
        }
    }

    fn write_word(&mut self, index: u8, value: u64) -> Result<(), String> {
        self.send(&write_frame(index, value))?;
        match self.recv(1)?[0] {
            WRITE_ACK => Ok(()),
            b => Err(unexpected("write", b)),
        }
    }

    fn read_word(&mut self, index: u8) -> Result<u64, String> {
        self.send(&read_frame(index))?;
        let b = self.recv(8)?;
        Ok(u64::from_le_bytes(b.try_into().expect("8 bytes")))
    }

    fn exec(&mut self, opcode: u8, base: u64, offset: u64) -> Result<Status, String> {
        self.send(&exec_frame(opcode, base, offset))?;
        parse_status(self.recv(1)?[0])
    }
}

fn num(s: &str) -> Result<u64, String> {
    let r = match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        Some(h) => u64::from_str_radix(&h.replace('_', ""), 16),
        None => s.replace('_', "").parse(),
    };
    r.map_err(|_| format!("not a number: {s}"))
}

fn opcode(s: &str) -> Result<u8, String> {
    if let Some(op) = Op::parse(s) {
        return Ok(op as u8);
    }
    match num(s)? {
        n @ 0..=7 => Ok(n as u8),
        _ => Err(format!(
            "opcode must be get/test/set/clear/toggle or 0..7: {s}"
        )),
    }
}

fn index(s: &str, words: usize) -> Result<u8, String> {
    let n = num(s)?;
    u8::try_from(n)
        .ok()
        .filter(|&i| (i as usize) < words)
        .ok_or_else(|| format!("index must be 0..{}: {s}", words - 1))
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

/// Fill the RAM, run random operations, and compare every status and the final
/// RAM contents against the host model. This is the on-hardware acceptance test.
fn selftest(port: &mut Port, words: usize, ops: u64, seed: u64) -> Result<(), String> {
    let mut rng = Rng(seed.max(1));
    let mut ram = vec![0u64; words];
    port.ping()?;
    for (i, w) in ram.iter_mut().enumerate() {
        *w = rng.next();
        port.write_word(i as u8, *w)?;
    }
    let mut mismatches = 0u64;
    for n in 0..ops {
        let r = rng.next();
        let mut op = (r % 8) as u8;
        if op > 4 && r % 3 != 0 {
            op -= 4; // mostly defined opcodes
        }
        let (base, offset) = if r % 10 == 0 {
            (rng.next(), rng.next()) // mostly out of range: exercises faults
        } else {
            (
                rng.next() % (words as u64 * 8),
                rng.next() % (words as u64 * 64),
            )
        };
        let want = model_exec(&mut ram, op, base, offset);
        let got = port.exec(op, base, offset)?;
        if got.error != want.error || (!want.error && got.bit != want.bit) {
            mismatches += 1;
            eprintln!(
                "op {n}: exec {op} base {base:#x} offset {offset:#x}: got {got:?}, expected {want:?}"
            );
        }
    }
    for (i, &w) in ram.iter().enumerate() {
        let got = port.read_word(i as u8)?;
        if got != w {
            mismatches += 1;
            eprintln!("word {i}: got {got:#018x}, expected {w:#018x}");
        }
    }
    println!("selftest: {ops} operations, {words} words checked, {mismatches} mismatches");
    if mismatches == 0 {
        Ok(())
    } else {
        Err("selftest FAILED".into())
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let mut port_path = None;
    let mut baud = 115_200u32;
    let mut words = WORDS;
    let mut rest = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--port" => port_path = it.next().cloned(),
            "--baud" => baud = num(it.next().ok_or("--baud needs a value")?)? as u32,
            "--words" => {
                words = num(it.next().ok_or("--words needs a value")?)? as usize;
                if !(1..=256).contains(&words) {
                    return Err("--words must be 1..256".into());
                }
            }
            "-h" | "--help" => {
                println!(
                    "{}",
                    include_str!("main.rs")
                        .lines()
                        .take(13)
                        .map(|l| l.trim_start_matches("//!"))
                        .collect::<Vec<_>>()
                        .join("\n")
                );
                return Ok(());
            }
            _ => rest.push(a.as_str()),
        }
    }
    let path = port_path.ok_or("missing --port <serial device>")?;
    let mut port = Port::open(&path, baud)?;
    match rest.as_slice() {
        ["ping"] => {
            port.ping()?;
            println!("pong");
        }
        ["write", i, v] => port.write_word(index(i, words)?, num(v)?)?,
        ["read", i] => println!("{:#018x}", port.read_word(index(i, words)?)?),
        ["exec", op, base, offset] => {
            let s = port.exec(opcode(op)?, num(base)?, num(offset)?)?;
            if s.error {
                println!("error");
            } else {
                println!("{}", s.bit as u8);
            }
        }
        ["selftest"] => selftest(&mut port, words, 1000, 1)?,
        ["selftest", n] => selftest(&mut port, words, num(n)?, 1)?,
        ["selftest", n, seed] => selftest(&mut port, words, num(n)?, num(seed)?)?,
        _ => return Err("unknown command; see --help".into()),
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("bitacc: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_numbers_and_opcodes() {
        assert_eq!(num("0x10").unwrap(), 16);
        assert_eq!(num("1_000").unwrap(), 1000);
        assert!(num("zz").is_err());
        assert_eq!(opcode("set").unwrap(), 2);
        assert_eq!(opcode("7").unwrap(), 7);
        assert!(opcode("8").is_err());
        assert_eq!(index("255", 256).unwrap(), 255);
        assert!(index("256", 256).is_err());
        assert_eq!(index("3", 4).unwrap(), 3);
        assert!(index("4", 4).is_err());
    }
}
