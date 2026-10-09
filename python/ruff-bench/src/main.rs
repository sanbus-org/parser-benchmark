use ruff_python_parser::{lexer::lex, parse_module, Mode};
use std::time::Instant;

fn measure(label: &str, bytes: usize, iterations: usize, mut run: impl FnMut()) {
    for _ in 0..iterations / 10 { run(); }
    let mut best = f64::MAX;
    for _ in 0..5 {
        let start = Instant::now();
        for _ in 0..iterations { run(); }
        best = best.min(start.elapsed().as_secs_f64());
    }
    println!("{label:32} {:8.2} MB/s", (bytes * iterations) as f64 / best / 1048576.0);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let source = std::fs::read_to_string(&args[1]).unwrap();
    let iterations: usize = args[2].parse().unwrap();
    assert!(parse_module(&source).is_ok());
    measure("ruff 0.16.0 parse_module (AST)", source.len(), iterations, || {
        std::hint::black_box(parse_module(std::hint::black_box(&source)).is_ok());
    });
    measure("ruff 0.16.0 lexer only", source.len(), iterations, || {
        let mut lexer = lex(std::hint::black_box(&source), Mode::Module);
        let mut tokens = 0usize;
        while !lexer.next_token().is_eof() { tokens += 1; }
        std::hint::black_box(tokens);
    });
}
